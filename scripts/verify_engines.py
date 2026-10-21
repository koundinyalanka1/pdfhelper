import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass

ROOT = Path(__file__).resolve().parent.parent
PDF_CATEGORIES = ("languages", "light", "heavy", "features", "pictures", "epics", "huge", "scans", "photo_languages", "ocr")
OFFICE_TYPES = {
    "shared": ("docx", "odt", "xlsx", "ods", "pptx", "odp"),
    "word": ("docx", "odt", "rtf", "doc"),
    "sheet": ("xlsx", "ods", "xls"),
    "slide": ("pptx", "odp", "ppt"),
}
ENGINES = ("shared", "pdf", "text", "sheet", "word", "slide", "archive")
OUTPUT_LIMIT = 16 << 20


class Unsupported(RuntimeError):
    pass


class CorpusError(RuntimeError):
    pass


@dataclass
class Outcome:
    status: str
    exit_code: object
    elapsed_ms: int
    sampled_peak_rss_bytes: object
    stdout: str = ""
    stderr: str = ""
    detail: str = ""


class WindowsJob:
    def __init__(self, process):
        from ctypes import wintypes as w

        class Basic(ctypes.Structure):
            _fields_ = [("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64), ("flags", w.DWORD),
                        ("min_ws", ctypes.c_size_t), ("max_ws", ctypes.c_size_t), ("active", w.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD)]

        class Io(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ("read_ops", "write_ops", "other_ops", "read", "write", "other")]

        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", Io), ("process_limit", ctypes.c_size_t), ("job_limit", ctypes.c_size_t),
                        ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

        class Pids(ctypes.Structure):
            _fields_ = [("assigned", w.DWORD), ("count", w.DWORD), ("ids", ctypes.c_size_t * 4096)]

        class Counters(ctypes.Structure):
            _fields_ = [("size", w.DWORD), ("faults", w.DWORD), ("peak_ws", ctypes.c_size_t), ("ws", ctypes.c_size_t),
                        ("peak_paged", ctypes.c_size_t), ("paged", ctypes.c_size_t), ("peak_nonpaged", ctypes.c_size_t),
                        ("nonpaged", ctypes.c_size_t), ("pagefile", ctypes.c_size_t), ("peak_pagefile", ctypes.c_size_t)]

        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.psapi = ctypes.WinDLL("psapi", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.api.CreateJobObjectW.restype = w.HANDLE
        self.api.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.api.SetInformationJobObject.restype = w.BOOL
        self.api.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.api.AssignProcessToJobObject.restype = w.BOOL
        self.api.QueryInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p]
        self.api.QueryInformationJobObject.restype = w.BOOL
        self.api.TerminateJobObject.argtypes = [w.HANDLE, w.UINT]
        self.api.TerminateJobObject.restype = w.BOOL
        self.api.CloseHandle.argtypes = [w.HANDLE]
        self.api.CloseHandle.restype = w.BOOL
        self.api.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.api.OpenProcess.restype = w.HANDLE
        self.psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD]
        self.psapi.GetProcessMemoryInfo.restype = w.BOOL
        self.Pids, self.Counters = Pids, Counters
        self.process = process
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise Unsupported("CreateJobObjectW failed")
        info = Extended()
        info.basic.flags = 0x2000
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
            self.close()
            raise Unsupported("cannot set kill-on-close job limit")
        if not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            error = ctypes.get_last_error()
            self.close()
            raise Unsupported(f"cannot supervise Windows process tree (Win32 {error})")

    def peak_rss(self):
        ids = self.Pids()
        if not self.api.QueryInformationJobObject(self.handle, 3, ctypes.byref(ids), ctypes.sizeof(ids), None):
            raise Unsupported("cannot enumerate Windows job processes")
        if ids.count > 4096:
            raise Unsupported("Windows job has too many processes to monitor")
        total = 0
        observed = False
        for pid in set(ids.ids[:ids.count]) | {self.process.pid}:
            own = pid == self.process.pid
            handle = int(self.process._handle) if own else self.api.OpenProcess(0x410, False, pid)
            if not handle:
                if ctypes.get_last_error() == 87:
                    continue
                raise Unsupported("cannot open child process for RSS monitoring")
            try:
                counts = self.Counters()
                counts.size = ctypes.sizeof(counts)
                if self.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counts), ctypes.sizeof(counts)):
                    total += counts.peak_ws
                    observed = True
                elif own and self.process.poll() is None:
                    raise Unsupported("GetProcessMemoryInfo failed")
            finally:
                if not own:
                    self.api.CloseHandle(handle)
        return total if observed else None

    def stop(self):
        if not self.api.TerminateJobObject(self.handle, 1):
            raise Unsupported("TerminateJobObject failed")

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


def linux_peak_rss(pid):
    pending, seen, total, observed = [pid], set(), 0, False
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        try:
            status = Path(f"/proc/{current}/status").read_text()
            values = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
            if "VmHWM" in values:
                total += int(values["VmHWM"].split()[0]) * 1024
                observed = True
            elif not values.get("State", "").strip().startswith(("Z", "X")):
                raise Unsupported("/proc status has no VmHWM")
            children = Path(f"/proc/{current}/task/{current}/children")
            pending.extend(int(value) for value in children.read_text().split())
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (PermissionError, ValueError, OSError) as error:
            raise Unsupported(f"cannot read process RSS: {error}") from error
    return total if observed else None


def run_command(command, *, timeout=45, rss_bytes=512 << 20, cwd=ROOT, env=None):
    if timeout <= 0 or (rss_bytes is not None and rss_bytes <= 0):
        raise ValueError("positive timeout and RSS limit required")
    start = time.monotonic()
    if rss_bytes is not None and os.name != "nt" and not sys.platform.startswith("linux"):
        return Outcome("UNSUPPORTED", None, 0, None, detail="RSS monitoring supports Linux /proc and Windows process counters only")
    environment = os.environ.copy()
    environment.update(env or {})
    job, process, peak, status, detail = None, None, None, None, ""
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            process = subprocess.Popen([str(part) for part in command], cwd=cwd, env=environment,
                                       stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                       start_new_session=os.name != "nt")
            if os.name == "nt":
                job = WindowsJob(process)
            while True:
                if rss_bytes is not None:
                    current = job.peak_rss() if job else linux_peak_rss(process.pid)
                    if current is not None:
                        peak = max(peak or 0, current)
                        if current > rss_bytes:
                            status, detail = "MEMORY_LIMIT", f"sampled process-tree peak RSS {current} exceeds {rss_bytes}"
                            break
                if process.poll() is not None:
                    break
                if time.monotonic() - start >= timeout:
                    status, detail = "TIMEOUT", f"deadline {timeout}s; process tree terminated and child reaped"
                    break
                if output.tell() + errors.tell() > OUTPUT_LIMIT:
                    status, detail = "OUTPUT_LIMIT", "worker output exceeded bounded capture"
                    break
                time.sleep(0.005)
        except Unsupported as error:
            status, detail = "UNSUPPORTED", str(error)
        except OSError as error:
            status, detail = "IO", str(error)
        finally:
            if process is not None:
                if job:
                    if status is not None:
                        job.stop()
                    job.close()
                elif os.name != "nt":
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                elif process.poll() is None:
                    subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
                    process.kill()
                process.wait(timeout=15)
        output.seek(0)
        errors.seek(0)
        stdout = output.read(OUTPUT_LIMIT).decode("utf-8", "replace")
        stderr = errors.read(OUTPUT_LIMIT).decode("utf-8", "replace")
    code = process.returncode if process is not None else None
    if status is None:
        if code == 0:
            status = "OK"
        elif code == 81 or (code == 101 and ("panicked" in stderr or "PANIC" in stdout)):
            status = "PANIC"
        elif code == 83:
            status = "UNSUPPORTED"
        elif code is not None and (code < 0 or code >= 0x80000000):
            status = "CRASH"
        else:
            status = "FAILED"
    if status == "OK" and rss_bytes is not None and peak is None:
        status, detail = "UNSUPPORTED", "worker finished before any RSS observation; memory coverage is not established"
    return Outcome(status, code, round((time.monotonic() - start) * 1000), peak, stdout, stderr, detail)


def required_files(root, categories):
    if not categories:
        raise CorpusError("EMPTY_CORPUS: no categories selected")
    result = []
    for category, extensions in categories:
        folder = root / category
        if not folder.is_dir():
            raise CorpusError(f"MISSING_CORPUS: {folder}")
        files = sorted(path for path in folder.rglob("*") if path.is_file() and not path.is_symlink()
                       and path.suffix.lower().lstrip(".") in extensions and path.stat().st_size > 0)
        if not files:
            raise CorpusError(f"EMPTY_CORPUS: {folder}")
        result.extend(files)
    return sorted(set(result))


def categories_for(engine, requested=None):
    if engine == "pdf":
        return [(name, {"pdf"}) for name in (requested or PDF_CATEGORIES)]
    if engine in OFFICE_TYPES:
        return [(f"office/{ext}", {ext}) for ext in OFFICE_TYPES[engine]]
    return [(engine, {"txt", "md", "json", "html"} if engine == "text" else {"zip", "tar", "gz", "tgz"})]


def workspace(engine):
    return ROOT / "packages" / ("doc_common" if engine == "shared" else f"flutter_{engine}_core/rust")


def emit(label, outcome):
    row = asdict(outcome)
    row["operation"] = label
    print(json.dumps(row, ensure_ascii=True), flush=True)
    return outcome.status == "OK"


def cargo_artifacts(engine, example=None):
    command = ["cargo", "build" if example else "test", "--release", "--locked", "-j", "2", "--message-format=json"]
    if example:
        command.extend(["-p", "pdf_ffi" if engine == "pdf" else "doc_opc", "--example", example])
    else:
        command.extend(["--workspace", "--no-run"])
    outcome = run_command(command, timeout=900, rss_bytes=None, cwd=workspace(engine))
    if outcome.status != "OK":
        emit(f"{engine}: build", outcome)
        return []
    found = []
    for line in outcome.stdout.splitlines():
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("reason") == "compiler-artifact" and message.get("executable"):
            if example or message.get("profile", {}).get("test"):
                found.append((message["target"]["name"], Path(message["executable"])))
    if not found:
        emit(f"{engine}: build", Outcome("MISSING_COVERAGE", None, 0, None, detail="Cargo produced no requested executable"))
    return found


def selected_tests(artifacts, corpus=False):
    selected = []
    for target, binary in artifacts:
        listed = run_command([binary, "--list"], timeout=30, rss_bytes=None)
        if listed.status != "OK":
            emit(f"list {target}", listed)
            continue
        for line in listed.stdout.splitlines():
            if not line.endswith(": test"):
                continue
            name = line[:-6]
            if corpus:
                match = re.search(r"corpus|sweep", name, re.I)
            else:
                match = not re.search(r"corpus|sweep", name, re.I) and (target in ("mutate", "hostile", "regression", "phase10", "b9") or re.search(r"fuzz|mutat|hostile|small_stack", name, re.I))
            if match:
                selected.append((binary, name))
    return selected


def fuzz(engines, timeout, rss):
    okay = True
    for engine in engines:
        tests = selected_tests(cargo_artifacts(engine))
        if not tests or not any(re.search(r"fuzz|mutat", name, re.I) for _, name in tests):
            emit(engine, Outcome("MISSING_COVERAGE", None, 0, None, detail="no fixed-seed mutation tests discovered; engine owner must add them"))
            okay = False
        for binary, name in tests:
            for stack in (None, "524288"):
                env = {"RUST_MIN_STACK": stack} if stack else {}
                result = run_command([binary, name, "--exact", "--nocapture", "--test-threads=1"], timeout=timeout, rss_bytes=rss, env=env)
                okay = emit(f"{engine}:{name}:stack={stack or 'default'}", result) and okay
    return 0 if okay else 1


def pdf_operation(binary, operation, file, page=0, password="", output=None, timeout=45, rss=512 << 20):
    command = [binary, operation, file, str(page), password]
    if output is not None:
        command.append(output)
    result = run_command(command, timeout=timeout, rss_bytes=rss, env={"RUST_MIN_STACK": "524288"})
    try:
        payload = json.loads(result.stdout)
    except ValueError:
        payload = {}
    return result, payload


def pdf_sweep(binary, files, timeout, rss):
    okay = True
    for file in files:
        inspected, info = pdf_operation(binary, "inspect", file, timeout=timeout, rss=rss)
        okay = emit(f"pdf:inspect:{file}", inspected) and okay
        if inspected.status != "OK":
            continue
        pages = info.get("pages", 0)
        if not isinstance(pages, int) or pages < 1:
            okay = emit(str(file), Outcome("FAILED", None, 0, None, detail="inspection returned no page count")) and okay
            continue
        original = []
        for page in range(pages):
            for operation in ("render", "text"):
                result, payload = pdf_operation(binary, operation, file, page, timeout=timeout, rss=rss)
                okay = emit(f"pdf:{operation}:{file}:page={page}", result) and okay
                if operation == "text":
                    original.append(payload.get("text_hash"))
        with tempfile.TemporaryDirectory(prefix="dochelper_pdf_sweep_") as scratch:
            for operation in ("save", "edit", "export"):
                saved = Path(scratch) / f"{operation}.pdf"
                result, _ = pdf_operation(binary, operation, file, output=saved, timeout=timeout, rss=rss)
                okay = emit(f"pdf:{operation}:{file}", result) and okay
                if result.status != "OK":
                    continue
                for page in range(pages):
                    result, payload = pdf_operation(binary, "text", saved, page, timeout=timeout, rss=rss)
                    if result.status == "OK" and (original[page] is None or payload.get("text_hash") != original[page]):
                        result.status, result.detail = "CONTENT_CHANGED", f"saved text differs on page {page}"
                    okay = emit(f"pdf:reopen-{operation}:{file}:page={page}", result) and okay
    return okay


def shared_sweep(binary, files, timeout, rss):
    okay = True
    soffice = shutil.which("soffice")
    if not soffice:
        emit("shared:LibreOffice", Outcome("UNSUPPORTED", None, 0, None, detail="soffice is required to validate saved Office files"))
        okay = False
    for file in files:
        result = run_command([binary, "inspect", file], timeout=timeout, rss_bytes=rss)
        okay = emit(f"shared:inspect:{file}", result) and okay
        if result.status != "OK":
            continue
        parts = [bytes.fromhex(line.split("\t", 1)[1]).decode("utf-8") for line in result.stdout.splitlines() if line.startswith("part\t")]
        if not parts:
            okay = emit(str(file), Outcome("FAILED", None, 0, None, detail="no package parts listed")) and okay
        for part in parts:
            result = run_command([binary, "read", file, part], timeout=timeout, rss_bytes=rss)
            okay = emit(f"shared:read:{file}:{part}", result) and okay
        with tempfile.TemporaryDirectory(prefix="dochelper_shared_sweep_") as scratch:
            for operation in ("save", "edit"):
                saved = Path(scratch) / f"{operation}{file.suffix}"
                result = run_command([binary, operation, file, saved], timeout=timeout, rss_bytes=rss)
                okay = emit(f"shared:{operation}:{file}", result) and okay
                if result.status == "OK" and soffice:
                    destination = Path(scratch) / operation
                    destination.mkdir()
                    profile = (Path(scratch) / f"profile-{operation}").as_uri()
                    result = run_command([soffice, f"-env:UserInstallation={profile}", "--headless", "--convert-to", "pdf", "--outdir", destination, saved], timeout=timeout, rss_bytes=rss)
                    if result.status == "OK" and not (destination / f"{operation}.pdf").is_file():
                        result.status, result.detail = "FAILED", "LibreOffice returned success without an output PDF"
                    okay = emit(f"shared:LibreOffice-{operation}:{file}", result) and okay
    return okay


def sweep(engines, corpus, categories, timeout, rss):
    plans, okay = {}, True
    for engine in engines:
        try:
            plans[engine] = required_files(corpus, categories_for(engine, categories if engine == "pdf" else None))
        except CorpusError as error:
            emit(engine, Outcome("MISSING_CORPUS", None, 0, None, detail=str(error)))
            okay = False
    if not okay:
        return 1
    for engine, files in plans.items():
        if engine in ("shared", "pdf"):
            artifacts = cargo_artifacts(engine, f"phase10_{engine}")
            if not artifacts:
                okay = False
                continue
            run = pdf_sweep if engine == "pdf" else shared_sweep
            okay = run(artifacts[0][1], files, timeout, rss) and okay
        else:
            tests = selected_tests(cargo_artifacts(engine), corpus=True)
            if not tests:
                emit(engine, Outcome("MISSING_COVERAGE", None, 0, None, detail="no corpus/sweep tests discovered; engine owner must integrate DOC_CORPUS_ROOT"))
                okay = False
            for binary, name in tests:
                result = run_command([binary, name, "--exact", "--include-ignored", "--nocapture", "--test-threads=1"], timeout=timeout, rss_bytes=rss,
                                     env={"DOC_CORPUS_ROOT": str(corpus), "RUST_MIN_STACK": "524288"})
                okay = emit(f"{engine}:{name}", result) and okay
    return 0 if okay else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bounded Phase10 verification; failures and unsupported checks never count as passes")
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("inventory", "fuzz", "sweep"):
        command = sub.add_parser(mode)
        command.add_argument("--only", default="shared,pdf" if mode == "sweep" else ",".join(ENGINES))
        command.add_argument("--corpus", type=Path, default=ROOT / "test_corpus")
        command.add_argument("--category", action="append", help="explicit PDF subset; still fails if any selected category is missing or empty")
        command.add_argument("--timeout", type=float, default=360 if mode == "fuzz" else 45)
        command.add_argument("--rss-mib", type=int, default=1024 if mode == "fuzz" else 512)
    command = sub.add_parser("pdf-operation")
    command.add_argument("--binary", type=Path, default=workspace("pdf") / "target/release/examples" / ("phase10_pdf.exe" if os.name == "nt" else "phase10_pdf"))
    command.add_argument("--operation", choices=("inspect", "render", "text", "save", "edit", "export"), required=True)
    command.add_argument("--file", type=Path, required=True)
    command.add_argument("--page", type=int, default=0)
    command.add_argument("--password", default="")
    command.add_argument("--output", type=Path)
    command.add_argument("--timeout", type=float, default=45)
    command.add_argument("--rss-mib", type=int, default=512)
    args = parser.parse_args(argv)
    if args.timeout <= 0 or args.rss_mib <= 0:
        parser.error("timeout and RSS limit must be positive")
    rss = args.rss_mib << 20
    if args.mode == "pdf-operation":
        if not args.binary.is_file():
            result = Outcome("MISSING_TOOL", None, 0, None, detail="build cargo --example phase10_pdf in the PDF workspace before running the sweep")
            payload = {}
        else:
            result, payload = pdf_operation(args.binary, args.operation, args.file, args.page, args.password, args.output, args.timeout, rss)
        print(json.dumps({**asdict(result), "result": payload}, ensure_ascii=True))
        return 0 if result.status == "OK" else 1
    engines = args.only.split(",")
    if not engines or any(engine not in ENGINES for engine in engines):
        parser.error("--only must name shared,pdf,text,sheet,word,slide,archive")
    if args.category and any(engine != "pdf" for engine in engines):
        parser.error("--category requires --only pdf")
    if args.mode == "inventory":
        print(json.dumps({"corpus": str(args.corpus), "free_disk_bytes": shutil.disk_usage(ROOT).free}))
        okay = True
        for engine in engines:
            for category in categories_for(engine, args.category):
                try:
                    files = required_files(args.corpus, [category])
                    print(json.dumps({"engine": engine, "category": category[0], "files": len(files), "bytes": sum(file.stat().st_size for file in files)}))
                except CorpusError as error:
                    print(json.dumps({"engine": engine, "category": category[0], "status": "MISSING_CORPUS", "detail": str(error)}))
                    okay = False
        return 0 if okay else 1
    if args.mode == "fuzz":
        return fuzz(engines, args.timeout, rss)
    return sweep(engines, args.corpus.resolve(), args.category, args.timeout, rss)


if __name__ == "__main__":
    sys.exit(main())
