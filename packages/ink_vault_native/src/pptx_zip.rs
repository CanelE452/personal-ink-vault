//! Bounded, single-disk ZIP copying for PPTX edits.
//!
//! Unchanged entries keep their local records byte for byte. Rebuilding those
//! records through a general ZIP writer can change their encoding flags.
use crate::{ApiError, ApiResult, error};
use flate2::Compression;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Seek, SeekFrom, Write};
use std::ops::Range;

pub(super) const MAX_PACKAGE: usize = 128 * 1024 * 1024;
pub(super) const MAX_ENTRIES: usize = 10_000;
const MAX_CENTRAL: usize = 32 * 1024 * 1024;
const END: [u8; 4] = *b"PK\x05\x06";
const CENTRAL: [u8; 4] = *b"PK\x01\x02";
const LOCAL: [u8; 4] = *b"PK\x03\x04";
const DESCRIPTOR: [u8; 4] = *b"PK\x07\x08";
const UTF8: u16 = 0x800;
const DEFERRED: u16 = 8;

pub(super) fn invalid_zip() -> ApiError {
    error("invalid_pptx", "The PPTX package is invalid or unsupported")
}

pub(super) fn io_error(_: std::io::Error) -> ApiError {
    error("file_io", "Could not read or write the private PPTX files")
}

fn require(value: bool) -> ApiResult<()> {
    if value { Ok(()) } else { Err(invalid_zip()) }
}

fn le16(data: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(data[offset..offset + 2].try_into().unwrap())
}

fn le32(data: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(data[offset..offset + 4].try_into().unwrap())
}

fn set16(data: &mut [u8], offset: usize, value: u16) {
    data[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn set32(data: &mut [u8], offset: usize, value: u32) {
    data[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn exact_at(input: &mut (impl Read + Seek), offset: usize, bytes: &mut [u8]) -> ApiResult<()> {
    input
        .seek(SeekFrom::Start(offset as u64))
        .map_err(io_error)?;
    input.read_exact(bytes).map_err(|_| invalid_zip())
}

fn no_zip64(mut extra: &[u8]) -> ApiResult<()> {
    while !extra.is_empty() {
        require(extra.len() >= 4 && le16(extra, 0) != 1)?;
        let length = le16(extra, 2) as usize;
        require(length <= extra.len() - 4)?;
        extra = &extra[length + 4..];
    }
    Ok(())
}

pub(super) fn canonical_part(name: &str) -> bool {
    let components = name.strip_suffix('/').unwrap_or(name);
    !components.is_empty()
        && name.len() <= u16::MAX as usize
        && !name
            .chars()
            .any(|c| c.is_control() || matches!(c, '\\' | ':' | '%' | '?' | '#'))
        && components
            .split('/')
            .all(|part| !matches!(part, "" | "." | ".."))
}

#[derive(Debug)]
pub(super) struct Entry {
    pub name: String,
    pub size: usize,
    central: Range<usize>,
    offset: usize,
    data_start: usize,
    compressed: usize,
    crc: u32,
    flags: u16,
    method: u16,
    descriptor_len: usize,
    stop: usize,
}

pub(super) struct Layout {
    pub entries: Vec<Entry>,
    pub expanded: usize,
    names: BTreeMap<String, usize>,
    folded_names: BTreeSet<String>,
    central: Vec<u8>,
    end: Vec<u8>,
    physical: Vec<usize>,
}

#[derive(Default)]
pub(super) struct PackageEdits {
    pub changed: BTreeMap<String, Vec<u8>>,
    pub added: BTreeMap<String, Vec<u8>>,
    pub removed: BTreeSet<String>,
}

impl Layout {
    pub fn parse(input: &mut (impl Read + Seek)) -> ApiResult<Self> {
        let length = input.seek(SeekFrom::End(0)).map_err(io_error)?;
        require((22..=MAX_PACKAGE as u64).contains(&length))?;
        let length = length as usize;
        let tail_start = length.saturating_sub(65_557);
        let mut tail = vec![0; length - tail_start];
        exact_at(input, tail_start, &mut tail)?;
        let pos = (0..=tail.len() - 22)
            .rev()
            .find(|&i| tail[i..i + 4] == END && i + 22 + le16(&tail, i + 20) as usize == tail.len())
            .ok_or_else(invalid_zip)?;
        let end = tail[pos..].to_vec();
        let count = le16(&end, 10) as usize;
        let central_size = le32(&end, 12) as usize;
        let central_start = le32(&end, 16) as usize;
        require(le16(&end, 4) == 0 && le16(&end, 6) == 0 && le16(&end, 8) as usize == count)?;
        require((1..=MAX_ENTRIES).contains(&count) && central_size <= MAX_CENTRAL)?;
        require(central_start.checked_add(central_size) == Some(tail_start + pos))?;

        let mut central = vec![0; central_size];
        exact_at(input, central_start, &mut central)?;
        let mut entries = Vec::with_capacity(count);
        let mut names = BTreeMap::new();
        let mut folded = BTreeSet::new();
        let mut at = 0;
        let mut expanded = 0usize;
        for index in 0..count {
            require(central.len() - at >= 46 && central[at..at + 4] == CENTRAL)?;
            let header = &central[at..at + 46];
            let name_len = le16(header, 28) as usize;
            let extra_len = le16(header, 30) as usize;
            let stop = at + 46 + name_len + extra_len + le16(header, 32) as usize;
            require(stop <= central.len() && le16(header, 34) == 0)?;
            let mode = le32(header, 38) >> 16;
            require(mode & 0o170000 != 0o120000)?;
            let flags = le16(header, 8);
            let method = le16(header, 10);
            require(flags & !(UTF8 | DEFERRED | 6) == 0 && matches!(method, 0 | 8))?;
            let name_bytes = &central[at + 46..at + 46 + name_len];
            require(flags & UTF8 != 0 || name_bytes.is_ascii())?;
            let name = std::str::from_utf8(name_bytes).map_err(|_| invalid_zip())?;
            require(canonical_part(name) && folded.insert(name.to_lowercase()))?;
            no_zip64(&central[at + 46 + name_len..at + 46 + name_len + extra_len])?;
            let size = le32(header, 24) as usize;
            let compressed = le32(header, 20) as usize;
            let offset = le32(header, 42) as usize;
            require(size <= MAX_PACKAGE && compressed <= MAX_PACKAGE && offset < central_start)?;
            require(method != 0 || size == compressed)?;
            require(!name.ends_with('/') || size == 0)?;
            expanded += size;
            require(expanded <= MAX_PACKAGE)?;
            entries.push(Entry {
                name: name.into(),
                size,
                central: at..stop,
                offset,
                data_start: 0,
                compressed,
                crc: le32(header, 16),
                flags,
                method,
                descriptor_len: 0,
                stop: 0,
            });
            names.insert(name.into(), index);
            at = stop;
        }
        require(at == central.len())?;
        let mut physical = (0..count).collect::<Vec<_>>();
        physical.sort_unstable_by_key(|&i| entries[i].offset);
        for (index, &entry_index) in physical.iter().enumerate() {
            let stop = physical
                .get(index + 1)
                .map_or(central_start, |&i| entries[i].offset);
            let entry = &mut entries[entry_index];
            require(stop >= entry.offset + 30)?;
            let mut header = [0; 30];
            exact_at(input, entry.offset, &mut header)?;
            require(
                header[..4] == LOCAL
                    && le16(&header, 6) == entry.flags
                    && le16(&header, 8) == entry.method,
            )?;
            let name_len = le16(&header, 26) as usize;
            let extra_len = le16(&header, 28) as usize;
            let data_start = entry.offset + 30 + name_len + extra_len;
            let payload_end = data_start + entry.compressed;
            require(payload_end <= stop && name_len == entry.name.len())?;
            let mut suffix = vec![0; name_len + extra_len];
            exact_at(input, entry.offset + 30, &mut suffix)?;
            require(&suffix[..name_len] == entry.name.as_bytes())?;
            no_zip64(&suffix[name_len..])?;
            let fields = [le32(&header, 14), le32(&header, 18), le32(&header, 22)];
            let expected = [entry.crc, entry.compressed as u32, entry.size as u32];
            let descriptor_len = if entry.flags & DEFERRED != 0 {
                require(payload_end + 12 <= stop)?;
                let mut descriptor = [0; 16];
                exact_at(input, payload_end, &mut descriptor[..12])?;
                let signed = descriptor[..4] == DESCRIPTOR;
                if signed {
                    require(payload_end + 16 <= stop)?;
                    exact_at(input, payload_end + 12, &mut descriptor[12..])?;
                }
                let start = if signed { 4 } else { 0 };
                require(
                    [
                        le32(&descriptor, start),
                        le32(&descriptor, start + 4),
                        le32(&descriptor, start + 8),
                    ] == expected,
                )?;
                require(
                    fields
                        .iter()
                        .zip(expected)
                        .all(|(&actual, wanted)| actual == 0 || actual == wanted),
                )?;
                12 + start
            } else {
                require(fields == expected)?;
                0
            };
            entry.data_start = data_start;
            entry.descriptor_len = descriptor_len;
            entry.stop = stop;
        }
        Ok(Self {
            entries,
            expanded,
            names,
            folded_names: folded,
            central,
            end,
            physical,
        })
    }

    pub fn entry(&self, name: &str) -> Option<&Entry> {
        self.names.get(name).map(|&index| &self.entries[index])
    }

    pub fn contains_casefold(&self, name: &str) -> bool {
        self.folded_names.contains(&name.to_lowercase())
    }

    pub fn read(
        &self,
        input: &mut (impl Read + Seek),
        name: &str,
        limit: usize,
    ) -> ApiResult<Vec<u8>> {
        let entry = self
            .entry(name)
            .filter(|e| !e.name.ends_with('/') && e.size <= limit)
            .ok_or_else(invalid_zip)?;
        let mut output = Vec::with_capacity(entry.size);
        read_payload(input, entry, &mut output)?;
        Ok(output)
    }

    pub fn verify_payloads(&self, input: &mut (impl Read + Seek)) -> ApiResult<()> {
        for entry in &self.entries {
            read_payload(input, entry, &mut std::io::sink())?;
        }
        Ok(())
    }

    pub fn rewrite(
        &self,
        input: &mut (impl Read + Seek),
        output: &mut impl Write,
        edits: &PackageEdits,
    ) -> ApiResult<()> {
        require(
            edits
                .changed
                .keys()
                .all(|name| self.entry(name).is_some() && !edits.removed.contains(name)),
        )?;
        require(edits.added.keys().all(|name| !self.contains_casefold(name)))?;
        require(edits.removed.iter().all(|name| self.entry(name).is_some()))?;
        let mut output = BoundedWriter {
            inner: output,
            length: 0,
        };
        let mut central = self.central.clone();
        let first = self.entries[self.physical[0]].offset;
        copy_interval(input, &mut output, 0..first)?;
        for &index in &self.physical {
            let entry = &self.entries[index];
            if edits.removed.contains(&entry.name) {
                continue;
            }
            let record = &mut central[entry.central.clone()];
            set32(record, 42, output.length as u32);
            if let Some(payload) = edits.changed.get(&entry.name) {
                let compressed = compress(entry.method, payload)?;
                let values = [
                    crc32fast::hash(payload),
                    compressed.len() as u32,
                    payload.len() as u32,
                ];
                let mut header = vec![0; entry.data_start - entry.offset];
                exact_at(input, entry.offset, &mut header)?;
                for (index, value) in values.into_iter().enumerate() {
                    let offset = 14 + index * 4;
                    if entry.flags & DEFERRED == 0 || le32(&header, offset) != 0 {
                        set32(&mut header, offset, value);
                    }
                    set32(record, 16 + index * 4, value);
                }
                output.append(&header)?;
                output.append(&compressed)?;
                if entry.descriptor_len == 16 {
                    output.append(&DESCRIPTOR)?;
                }
                if entry.descriptor_len != 0 {
                    for value in values {
                        output.append(&value.to_le_bytes())?;
                    }
                }
                let padding = entry.data_start + entry.compressed + entry.descriptor_len;
                copy_interval(input, &mut output, padding..entry.stop)?;
            } else {
                copy_interval(input, &mut output, entry.offset..entry.stop)?;
            }
        }
        if !edits.removed.is_empty() {
            central = self
                .entries
                .iter()
                .filter(|entry| !edits.removed.contains(&entry.name))
                .flat_map(|entry| central[entry.central.clone()].iter().copied())
                .collect();
        }
        for (name, payload) in &edits.added {
            let offset = output.length as u32;
            let compressed = compress(8, payload)?;
            let values = [
                crc32fast::hash(payload),
                compressed.len() as u32,
                payload.len() as u32,
            ];
            let mut local = [0; 30];
            local[..4].copy_from_slice(&LOCAL);
            set16(&mut local, 4, 20);
            set16(&mut local, 6, UTF8);
            set16(&mut local, 8, 8);
            set16(&mut local, 26, name.len() as u16);
            let mut record = [0; 46];
            record[..4].copy_from_slice(&CENTRAL);
            set16(&mut record, 4, 20);
            set16(&mut record, 6, 20);
            set16(&mut record, 8, UTF8);
            set16(&mut record, 10, 8);
            set16(&mut record, 28, name.len() as u16);
            set32(&mut record, 42, offset);
            for (index, value) in values.into_iter().enumerate() {
                set32(&mut local, 14 + 4 * index, value);
                set32(&mut record, 16 + 4 * index, value);
            }
            output.append(&local)?;
            output.append(name.as_bytes())?;
            output.append(&compressed)?;
            central.extend(record);
            central.extend(name.as_bytes());
        }
        let central_offset = output.length;
        output.append(&central)?;
        let count = self.entries.len() - edits.removed.len() + edits.added.len();
        require((1..=MAX_ENTRIES).contains(&count))?;
        let mut end = self.end.clone();
        set16(&mut end, 8, count as u16);
        set16(&mut end, 10, count as u16);
        set32(&mut end, 12, central.len() as u32);
        set32(&mut end, 16, central_offset as u32);
        output.append(&end)
    }

    pub fn verify_unchanged(&self, other: &Self, edits: &PackageEdits) -> ApiResult<()> {
        require(
            other.entries.len() == self.entries.len() - edits.removed.len() + edits.added.len(),
        )?;
        for entry in &self.entries {
            if edits.removed.contains(&entry.name) {
                require(!other.contains_casefold(&entry.name))?;
                continue;
            }
            if edits.changed.contains_key(&entry.name) {
                continue;
            }
            let retained = other.entry(&entry.name).ok_or_else(invalid_zip)?;
            require(
                (
                    entry.flags,
                    entry.method,
                    entry.size,
                    entry.crc,
                    entry.compressed,
                ) == (
                    retained.flags,
                    retained.method,
                    retained.size,
                    retained.crc,
                    retained.compressed,
                ),
            )?;
        }
        Ok(())
    }
}

fn read_payload(
    input: &mut (impl Read + Seek),
    entry: &Entry,
    output: &mut impl Write,
) -> ApiResult<()> {
    input
        .seek(SeekFrom::Start(entry.data_start as u64))
        .map_err(io_error)?;
    let source = input.take(entry.compressed as u64);
    if entry.method == 8 {
        let mut decoder = DeflateDecoder::new(source);
        verify_contents(&mut decoder, output, entry)?;
        require(decoder.total_in() == entry.compressed as u64)
    } else {
        let mut source = source;
        verify_contents(&mut source, output, entry)?;
        require(source.limit() == 0)
    }
}

fn verify_contents(input: &mut impl Read, output: &mut impl Write, entry: &Entry) -> ApiResult<()> {
    let mut buffer = [0; 32 * 1024];
    let mut remaining = entry.size;
    let mut crc = crc32fast::Hasher::new();
    while remaining != 0 {
        let chunk = remaining.min(buffer.len());
        let got = input
            .read(&mut buffer[..chunk])
            .map_err(|_| invalid_zip())?;
        require(got != 0)?;
        crc.update(&buffer[..got]);
        output.write_all(&buffer[..got]).map_err(io_error)?;
        remaining -= got;
    }
    require(
        input.read(&mut buffer[..1]).map_err(|_| invalid_zip())? == 0
            && crc.finalize() == entry.crc,
    )
}

fn compress(method: u16, payload: &[u8]) -> ApiResult<Vec<u8>> {
    if method == 0 {
        return Ok(payload.to_vec());
    }
    let mut compressor = DeflateEncoder::new(Vec::new(), Compression::default());
    compressor.write_all(payload).map_err(io_error)?;
    compressor.finish().map_err(io_error)
}

struct BoundedWriter<'a, W> {
    inner: &'a mut W,
    length: usize,
}

impl<W: Write> BoundedWriter<'_, W> {
    fn append(&mut self, data: &[u8]) -> ApiResult<()> {
        require(data.len() <= MAX_PACKAGE - self.length)?;
        self.inner.write_all(data).map_err(io_error)?;
        self.length += data.len();
        Ok(())
    }
}

fn copy_interval(
    input: &mut (impl Read + Seek),
    output: &mut BoundedWriter<'_, impl Write>,
    range: Range<usize>,
) -> ApiResult<()> {
    input
        .seek(SeekFrom::Start(range.start as u64))
        .map_err(io_error)?;
    let mut remaining = range.len();
    let mut buffer = [0; 64 * 1024];
    while remaining != 0 {
        let chunk = remaining.min(buffer.len());
        input
            .read_exact(&mut buffer[..chunk])
            .map_err(|_| invalid_zip())?;
        output.append(&buffer[..chunk])?;
        remaining -= chunk;
    }
    Ok(())
}
