//! Flat little-endian file helpers (no headers).

use sha2::{Digest, Sha256};
use std::path::Path;

pub fn le_u64(v: &[u64]) -> Vec<u8> {
    let mut b = Vec::with_capacity(v.len() * 8);
    for x in v {
        b.extend_from_slice(&x.to_le_bytes());
    }
    b
}

pub fn le_u32(v: &[u32]) -> Vec<u8> {
    let mut b = Vec::with_capacity(v.len() * 4);
    for x in v {
        b.extend_from_slice(&x.to_le_bytes());
    }
    b
}

/// Write bytes, return hex sha256.
pub fn write_file(path: &Path, bytes: &[u8]) -> String {
    std::fs::write(path, bytes).unwrap_or_else(|e| panic!("write {}: {e}", path.display()));
    let h = Sha256::digest(bytes);
    h.iter().map(|b| format!("{b:02x}")).collect()
}

fn read_bytes(path: &Path) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

pub fn read_u64(path: &Path) -> Vec<u64> {
    let b = read_bytes(path);
    assert_eq!(b.len() % 8, 0, "{} not a multiple of 8 bytes", path.display());
    b.chunks_exact(8).map(|c| u64::from_le_bytes(c.try_into().unwrap())).collect()
}

pub fn read_u32(path: &Path) -> Vec<u32> {
    let b = read_bytes(path);
    assert_eq!(b.len() % 4, 0, "{} not a multiple of 4 bytes", path.display());
    b.chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect()
}

pub fn read_u8(path: &Path) -> Vec<u8> {
    read_bytes(path)
}
