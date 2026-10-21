//! CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), slice-by-8.

const POLY: u32 = 0xEDB8_8320;

const fn make_tables() -> [[u32; 256]; 8] {
    let mut tables = [[0u32; 256]; 8];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ POLY } else { crc >> 1 };
            bit += 1;
        }
        tables[0][i] = crc;
        i += 1;
    }
    let mut t = 1;
    while t < 8 {
        let mut i = 0;
        while i < 256 {
            let prev = tables[t - 1][i];
            tables[t][i] = (prev >> 8) ^ tables[0][(prev & 0xFF) as usize];
            i += 1;
        }
        t += 1;
    }
    tables
}

static TABLES: [[u32; 256]; 8] = make_tables();

/// An incremental CRC-32.
#[derive(Clone, Copy, Debug)]
pub struct Crc32 {
    state: u32,
}

impl Default for Crc32 {
    fn default() -> Self {
        Self::new()
    }
}

impl Crc32 {
    pub fn new() -> Self {
        Self { state: !0 }
    }

    pub fn update(&mut self, data: &[u8]) {
        let mut crc = self.state;
        let (chunks, rest) = data.as_chunks::<8>();
        for chunk in chunks {
            let lo = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) ^ crc;
            let hi = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
            crc = TABLES[7][(lo & 0xFF) as usize]
                ^ TABLES[6][((lo >> 8) & 0xFF) as usize]
                ^ TABLES[5][((lo >> 16) & 0xFF) as usize]
                ^ TABLES[4][(lo >> 24) as usize]
                ^ TABLES[3][(hi & 0xFF) as usize]
                ^ TABLES[2][((hi >> 8) & 0xFF) as usize]
                ^ TABLES[1][((hi >> 16) & 0xFF) as usize]
                ^ TABLES[0][(hi >> 24) as usize];
        }
        for &byte in rest {
            crc = (crc >> 8) ^ TABLES[0][((crc ^ byte as u32) & 0xFF) as usize];
        }
        self.state = crc;
    }

    pub fn finish(&self) -> u32 {
        !self.state
    }
}

/// CRC-32 of a whole buffer.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = Crc32::new();
    crc.update(data);
    crc.finish()
}
