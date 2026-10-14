//! Dates: the MS-DOS timestamps ZIP stores and the Unix times TAR and gzip
//! store, as ISO 8601 text; and file times as DOS timestamps for new ZIPs.

use std::time::{SystemTime, UNIX_EPOCH};

use doc_zip::DosDateTime;

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
/// algorithm).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        2 if year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400)) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// An MS-DOS date and time as ISO 8601 local time (`2024-03-05T14:30:22`;
/// ZIP records no time zone), or `None` when the fields are not a real date,
/// as in archives written with a zero timestamp.
pub fn dos_to_iso(date: u16, time: u16) -> Option<String> {
    let year = 1980 + (date >> 9) as u32;
    let month = ((date >> 5) & 0x0F) as u32;
    let day = (date & 0x1F) as u32;
    let hour = time >> 11;
    let minute = (time >> 5) & 0x3F;
    let second = (time & 0x1F) * 2;
    if !(1..=12).contains(&month) || day == 0 || day > days_in_month(year, month) {
        return None;
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    Some(format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}"))
}

/// Seconds since 1970 as ISO 8601 UTC (`2024-03-05T14:30:22Z`), or `None`
/// outside the years 1 to 9999.
pub fn unix_to_iso(secs: i64) -> Option<String> {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    if !(1..=9999).contains(&year) {
        return None;
    }
    Some(format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem % 3600) / 60, rem % 60))
}

/// A file's modification time as the DOS timestamp ZIP stores, in local
/// time `utc_offset_minutes` east of UTC. Times before 1980 become
/// 1980-01-01, the earliest DOS time.
pub fn dos_from_system(time: SystemTime, utc_offset_minutes: i32) -> DosDateTime {
    let secs = match time.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(e) => -(e.duration().as_secs() as i64),
    };
    let local = secs.saturating_add(utc_offset_minutes as i64 * 60);
    let (year, month, day) = civil_from_days(local.div_euclid(86_400));
    if year < 1980 {
        return DosDateTime::EPOCH;
    }
    let rem = local.rem_euclid(86_400);
    DosDateTime::from_civil(
        year.min(2107) as i32,
        month,
        day,
        (rem / 3600) as u32,
        ((rem % 3600) / 60) as u32,
        (rem % 60) as u32,
    )
}
