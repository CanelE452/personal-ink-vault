pub(crate) const MAX_IMAGE: usize = 20 * 1024 * 1024;
const MAX_PIXELS: u64 = 40_000_000;

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Format {
    Png,
    Jpeg,
}

impl Format {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpeg",
        }
    }

    pub(crate) fn mime(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
        }
    }

    pub(crate) fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
        }
    }
}

pub(super) fn image_format(bytes: &[u8]) -> Option<Format> {
    image_info(bytes).map(|(format, _, _)| format)
}

pub(super) fn image_info(bytes: &[u8]) -> Option<(Format, u32, u32)> {
    if bytes.len() > MAX_IMAGE {
        return None;
    }
    if let Some(chunks) = bytes.strip_prefix(b"\x89PNG\r\n\x1a\n") {
        return png_dimensions(chunks).map(|(w, h)| (Format::Png, w, h));
    }
    if let Some(markers) = bytes.strip_prefix(b"\xff\xd8") {
        return jpeg_dimensions(markers).map(|(w, h)| (Format::Jpeg, w, h));
    }
    None
}

fn valid_dimensions(width: u32, height: u32) -> bool {
    width > 0 && height > 0 && u64::from(width) * u64::from(height) <= MAX_PIXELS
}

fn png_dimensions(mut bytes: &[u8]) -> Option<(u32, u32)> {
    let Some((b"IHDR", header, rest)) = png_chunk(bytes) else {
        return None;
    };
    let Ok(header) = <&[u8; 13]>::try_from(header) else {
        return None;
    };
    let width = u32::from_be_bytes(header[0..4].try_into().unwrap());
    let height = u32::from_be_bytes(header[4..8].try_into().unwrap());
    let depth = header[8];
    let color = header[9];
    if !valid_dimensions(width, height)
        || !matches!(
            (color, depth),
            (0, 1 | 2 | 4 | 8 | 16) | (2 | 4 | 6, 8 | 16) | (3, 1 | 2 | 4 | 8)
        )
        || !matches!(header[10..], [0, 0, 0 | 1])
    {
        return None;
    }
    bytes = rest;
    let mut palette = false;
    let mut data_size = 0;
    let mut data_ended = false;
    while let Some((kind, data, rest)) = png_chunk(bytes) {
        match kind {
            b"PLTE" if !palette && data_size == 0 && !matches!(color, 0 | 4) => {
                let colors = data.len() / 3;
                if data.len() % 3 != 0
                    || !(1..=256).contains(&colors)
                    || (color == 3 && colors > (1 << depth))
                {
                    return None;
                }
                palette = true;
            }
            b"IDAT" if !data_ended && (color != 3 || palette) => data_size += data.len(),
            b"IEND" => {
                return (data.is_empty() && rest.is_empty() && data_size > 0)
                    .then_some((width, height));
            }
            b"acTL" | b"fcTL" | b"fdAT" => return None,
            _ if kind[0].is_ascii_lowercase() => data_ended |= data_size != 0,
            _ => return None,
        }
        bytes = rest;
    }
    None
}

fn png_chunk(bytes: &[u8]) -> Option<(&[u8; 4], &[u8], &[u8])> {
    let length = u32::from_be_bytes(bytes.get(..4)?.try_into().ok()?) as usize;
    let end = 8usize.checked_add(length)?;
    let kind = bytes.get(4..8)?.try_into().ok()?;
    let checksum_end = end.checked_add(4)?;
    let checksum = u32::from_be_bytes(bytes.get(end..checksum_end)?.try_into().ok()?);
    (crc32fast::hash(&bytes[4..end]) == checksum)
        .then(|| (kind, &bytes[8..end], &bytes[checksum_end..]))
}

fn jpeg_dimensions(mut bytes: &[u8]) -> Option<(u32, u32)> {
    let mut frame = None;
    let mut in_scan = false;
    let mut scan_data = false;
    loop {
        if in_scan {
            let Some(marker) = bytes.iter().position(|byte| *byte == 0xff) else {
                return None;
            };
            scan_data |= marker > 0;
            bytes = &bytes[marker..];
        }
        let Some(first) = bytes.iter().position(|byte| *byte != 0xff) else {
            return None;
        };
        if first == 0 {
            return None;
        }
        let marker = bytes[first];
        bytes = &bytes[first + 1..];
        match marker {
            0x00 | 0xd0..=0xd7 if in_scan => {
                scan_data |= marker == 0x00;
                continue;
            }
            0xd9 => {
                return frame
                    .filter(|_| in_scan && scan_data && bytes.is_empty())
                    .map(|(width, height, _)| (width, height));
            }
            0x00 | 0x01 | 0xd0..=0xd8 => return None,
            _ => {}
        }
        if in_scan && !scan_data {
            return None;
        }
        let Some((segment, rest)) = jpeg_segment(bytes) else {
            return None;
        };
        in_scan = marker == 0xda;
        scan_data = false;
        match marker {
            0xc0..=0xc2 if frame.is_none() => {
                frame = Some(jpeg_frame(segment)?);
            }
            0xc4 | 0xdb | 0xdd | 0xe0..=0xef | 0xfe => {}
            0xda => {
                let components = usize::from(segment.first().copied().unwrap_or(0));
                if !frame.is_some_and(|(_, _, total)| (1..=total).contains(&components))
                    || segment.len() != 4 + 2 * components
                {
                    return None;
                }
            }
            _ => return None,
        }
        bytes = rest;
    }
}

fn jpeg_segment(bytes: &[u8]) -> Option<(&[u8], &[u8])> {
    let length = usize::from(u16::from_be_bytes(bytes.get(..2)?.try_into().ok()?));
    Some((bytes.get(2..length)?, bytes.get(length..)?))
}

fn jpeg_frame(segment: &[u8]) -> Option<(u32, u32, usize)> {
    let [8, h0, h1, w0, w1, count, ..] = *segment else {
        return None;
    };
    let width = u32::from(u16::from_be_bytes([w0, w1]));
    let height = u32::from(u16::from_be_bytes([h0, h1]));
    let components = usize::from(count);
    (valid_dimensions(width, height)
        && matches!(components, 1 | 3 | 4)
        && segment.len() == 6 + 3 * components)
        .then_some((width, height, components))
}
