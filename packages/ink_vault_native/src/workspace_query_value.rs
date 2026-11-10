use crate::{ApiResult, error, invalid};
use serde_json::{Number, Value, json};
use std::cmp::Ordering;
use std::collections::BTreeSet;
use std::sync::Arc;

pub(super) type Text = Arc<[u16]>;
pub(super) type Object = Arc<[(Text, V)]>;
pub(super) type QResult<T> = Result<T, Fault>;

#[derive(Clone, Debug)]
pub(super) enum V {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(Text),
    List(Arc<[V]>),
    Map(Object),
}

#[derive(Clone, Debug)]
pub(super) struct Fault {
    pub code: &'static str,
    pub message: &'static str,
    pub path: Vec<String>,
}

impl Fault {
    pub fn new(code: &'static str) -> Self {
        Self::message(code, "계산 입력이나 연산을 확인해 주세요.")
    }
    pub fn message(code: &'static str, message: &'static str) -> Self {
        Self {
            code,
            message,
            path: Vec::new(),
        }
    }
    pub fn value(&self) -> V {
        V::object([
            ("code", V::s(self.code)),
            ("message", V::s(self.message)),
            ("path", V::list(self.path.iter().map(V::s))),
        ])
    }
}

impl V {
    pub fn s(value: impl AsRef<str>) -> Self {
        Self::Str(value.as_ref().encode_utf16().collect::<Vec<_>>().into())
    }
    pub fn text(value: Vec<u16>) -> Self {
        Self::Str(value.into())
    }
    pub fn list(value: impl IntoIterator<Item = V>) -> Self {
        Self::List(value.into_iter().collect::<Vec<_>>().into())
    }
    pub fn object<const N: usize>(entries: [(&str, V); N]) -> Self {
        Self::Map(
            entries
                .into_iter()
                .map(|(k, v)| (text(k), v))
                .collect::<Vec<_>>()
                .into(),
        )
    }
    pub fn get(&self, key: &str) -> &V {
        static NULL: V = V::Null;
        let Self::Map(entries) = self else {
            return &NULL;
        };
        entries
            .iter()
            .find(|(k, _)| text_eq(k, key))
            .map(|(_, v)| v)
            .unwrap_or(&NULL)
    }
    pub fn has(&self, key: &str) -> bool {
        matches!(self, Self::Map(entries) if entries.iter().any(|(k,_)|text_eq(k,key)))
    }
    pub fn array(&self) -> Option<&[V]> {
        if let Self::List(values) = self {
            Some(values)
        } else {
            None
        }
    }
    pub fn map(&self) -> Option<&[(Text, V)]> {
        if let Self::Map(values) = self {
            Some(values)
        } else {
            None
        }
    }
    pub fn string(&self) -> Option<&Text> {
        if let Self::Str(value) = self {
            Some(value)
        } else {
            None
        }
    }
    pub fn utf8(&self) -> Option<String> {
        self.string().and_then(|v| String::from_utf16(v).ok())
    }
    pub fn int(&self) -> Option<i64> {
        if let Self::Int(v) = self {
            Some(*v)
        } else {
            None
        }
    }
    pub fn boolean(&self) -> Option<bool> {
        if let Self::Bool(v) = self {
            Some(*v)
        } else {
            None
        }
    }
    pub fn null(&self) -> bool {
        matches!(self, Self::Null)
    }
    pub fn number(&self) -> QResult<Num> {
        match self {
            Self::Int(v) => Ok(Num::Int(*v)),
            Self::Float(v) if v.is_finite() => Ok(Num::Float(*v)),
            _ => Err(Fault::message("type_error", "숫자가 필요한 계산입니다.")),
        }
    }
    pub fn boolean_value(&self) -> QResult<bool> {
        self.boolean()
            .ok_or_else(|| Fault::message("type_error", "논리 값이 필요한 계산입니다."))
    }
    pub fn text_value(&self) -> QResult<Text> {
        self.string()
            .cloned()
            .ok_or_else(|| Fault::message("type_error", "문자 값이 필요한 계산입니다."))
    }
    pub fn with(&self, key: &str, value: V) -> Self {
        let mut entries = self.map().unwrap_or_default().to_vec();
        if let Some((_, old)) = entries.iter_mut().find(|(k, _)| text_eq(k, key)) {
            *old = value;
        } else {
            entries.push((text(key), value));
        }
        Self::Map(entries.into())
    }
}

pub(super) fn text(value: &str) -> Text {
    value.encode_utf16().collect::<Vec<_>>().into()
}
pub(super) fn text_eq(value: &[u16], other: &str) -> bool {
    value.iter().copied().eq(other.encode_utf16())
}
pub(super) fn utf8(value: &[u16]) -> QResult<String> {
    String::from_utf16(value).map_err(|_| Fault::new("type_error"))
}

#[derive(Clone, Copy, Debug)]
pub(super) enum Num {
    Int(i64),
    Float(f64),
}
impl Num {
    pub fn f64(self) -> f64 {
        match self {
            Self::Int(v) => v as f64,
            Self::Float(v) => v,
        }
    }
    pub fn value(self) -> V {
        match self {
            Self::Int(v) => V::Int(v),
            Self::Float(v) => V::Float(v),
        }
    }
    pub fn finite(value: f64) -> QResult<Self> {
        if value.is_finite() {
            Ok(Self::Float(value))
        } else {
            Err(Fault::message(
                "numeric_overflow",
                "계산 값이 숫자 범위를 넘습니다.",
            ))
        }
    }
    pub fn negate(self) -> QResult<Self> {
        match self {
            Self::Int(v) => v.checked_neg().map(Self::Int).ok_or_else(integer_overflow),
            Self::Float(v) => Self::finite(-v),
        }
    }
    pub fn arithmetic(self, other: Self, op: &str) -> QResult<Self> {
        if let (Self::Int(a), Self::Int(b)) = (self, other) {
            let value = match op {
                "+" => a.checked_add(b),
                "-" => a.checked_sub(b),
                "*" => a.checked_mul(b),
                _ => return Err(Fault::new("argument_error")),
            };
            return value.map(Self::Int).ok_or_else(integer_overflow);
        }
        let (a, b) = (self.f64(), other.f64());
        Self::finite(match op {
            "+" => a + b,
            "-" => a - b,
            "*" => a * b,
            _ => return Err(Fault::new("argument_error")),
        })
    }
    pub fn equals(self, other: Self) -> bool {
        match (self, other) {
            (Self::Int(a), Self::Int(b)) => a == b,
            (Self::Float(a), Self::Float(b)) => a == b,
            (Self::Int(a), Self::Float(b)) | (Self::Float(b), Self::Int(a)) => {
                (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&b)
                    && b.fract() == 0.0
                    && b as i64 == a
            }
        }
    }
    pub fn compare(self, other: Self) -> Ordering {
        match (self, other) {
            (Self::Int(a), Self::Int(b)) => a.cmp(&b),
            (Self::Float(a), Self::Float(b)) => {
                if a == 0.0 && b == 0.0 {
                    a.is_sign_negative().cmp(&b.is_sign_negative()).reverse()
                } else {
                    a.partial_cmp(&b).expect("finite numbers")
                }
            }
            (Self::Int(a), Self::Float(b)) => int_float_compare(a, b),
            (Self::Float(a), Self::Int(b)) => int_float_compare(b, a).reverse(),
        }
    }
}
fn int_float_compare(a: i64, b: f64) -> Ordering {
    if b >= 9_223_372_036_854_775_808.0 {
        return Ordering::Less;
    }
    if b < -9_223_372_036_854_775_808.0 {
        return Ordering::Greater;
    }
    match a.cmp(&(b as i64)) {
        Ordering::Equal if b.fract() > 0.0 => Ordering::Less,
        Ordering::Equal if b.fract() < 0.0 || b == 0.0 && b.is_sign_negative() => Ordering::Greater,
        result => result,
    }
}
fn integer_overflow() -> Fault {
    Fault::message("numeric_overflow", "정수 계산 범위를 넘었습니다.")
}

pub(super) fn equal(a: &V, b: &V) -> bool {
    match (a, b) {
        (V::Null, V::Null) => true,
        (V::Bool(a), V::Bool(b)) => a == b,
        (V::Str(a), V::Str(b)) => a == b,
        (V::Int(_) | V::Float(_), V::Int(_) | V::Float(_)) => a
            .number()
            .expect("number")
            .equals(b.number().expect("number")),
        (V::List(a), V::List(b)) => {
            a.len() == b.len() && a.iter().zip(b.iter()).all(|(a, b)| equal(a, b))
        }
        (V::Map(a), V::Map(b)) => {
            a.len() == b.len()
                && a.iter().all(|(key, a)| {
                    b.iter()
                        .find(|(k, _)| k == key)
                        .is_some_and(|(_, b)| equal(a, b))
                })
        }
        _ => false,
    }
}
pub(super) fn empty(v: &V) -> bool {
    matches!(v, V::Null)
        || matches!(v,V::Str(v) if v.is_empty())
        || matches!(v,V::List(v) if v.is_empty())
        || matches!(v,V::Map(v) if v.is_empty())
}
pub(super) fn compare(a: &V, b: &V) -> QResult<Ordering> {
    match (a, b) {
        (V::Int(_) | V::Float(_), V::Int(_) | V::Float(_)) => Ok(a.number()?.compare(b.number()?)),
        (V::Str(a), V::Str(b)) => Ok(a.cmp(b)),
        (V::Bool(a), V::Bool(b)) => Ok(a.cmp(b)),
        _ => Err(Fault::message(
            "type_error",
            "서로 비교할 수 없는 값입니다.",
        )),
    }
}
pub(super) fn case_map(value: &[u16], upper: bool) -> Text {
    let table = if upper {
        super::workspace_query_case_table::UPPER
    } else {
        super::workspace_query_case_table::LOWER
    };
    let mut result = Vec::with_capacity(value.len());
    for scalar in char::decode_utf16(value.iter().copied()) {
        match scalar {
            Ok(scalar) => {
                let code = scalar as u32;
                let mapped = table
                    .binary_search_by_key(&code, |(source, _)| *source)
                    .map_or(code, |index| table[index].1);
                result.extend_from_slice(
                    char::from_u32(mapped)
                        .expect("observed Unicode scalar mapping")
                        .encode_utf16(&mut [0; 2]),
                );
            }
            Err(unpaired) => result.push(unpaired.unpaired_surrogate()),
        }
    }
    result.into()
}
pub(super) fn trim(value: &[u16]) -> Text {
    let space =
        |u: &u16| *u == 0xfeff || char::from_u32(*u as u32).is_some_and(char::is_whitespace);
    let start = value.iter().position(|v| !space(v)).unwrap_or(value.len());
    let end = value
        .iter()
        .rposition(|v| !space(v))
        .map_or(start, |i| i + 1);
    value[start..end].to_vec().into()
}
pub(super) fn scalar_len(value: &[u16]) -> usize {
    char::decode_utf16(value.iter().copied()).count()
}
pub(super) fn find(source: &[u16], pattern: &[u16], from: usize) -> Option<usize> {
    if pattern.is_empty() {
        return (from <= source.len()).then_some(from);
    }
    source
        .get(from..)?
        .windows(pattern.len())
        .position(|v| v == pattern)
        .map(|p| p + from)
}

pub(super) fn bounded(value: &V) -> QResult<()> {
    fn visit(v: &V, depth: usize, units: &mut usize, nodes: &mut usize) -> QResult<()> {
        *nodes += 1;
        if *nodes > 10000 || depth > 64 {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 구조 한도를 넘었습니다.",
            ));
        }
        match v {
            V::Str(v) => *units += v.len(),
            V::List(values) => {
                for value in values.iter() {
                    visit(value, depth + 1, units, nodes)?;
                }
            }
            V::Map(values) => {
                for (key, value) in values.iter() {
                    *units += key.len();
                    visit(value, depth + 1, units, nodes)?;
                }
            }
            V::Float(v) if !v.is_finite() => return Err(Fault::new("numeric_overflow")),
            _ => (),
        }
        if *units > 1000000 {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 크기 한도를 넘었습니다.",
            ));
        }
        Ok(())
    }
    visit(value, 0, &mut 0, &mut 0)
}

pub(super) fn stringify(value: &V) -> QResult<Text> {
    if value.null() {
        return Ok(text(""));
    }
    if let V::Str(value) = value {
        return Ok(value.clone());
    }
    json_text(value)
}
pub(super) fn json_text(value: &V) -> QResult<Text> {
    json_text_limited(value, 8000000)
}
pub(super) fn json_text_limited(value: &V, limit: usize) -> QResult<Text> {
    fn write(v: &V, out: &mut Vec<u16>, limit: usize) -> QResult<()> {
        match v {
            V::Null => out.extend("null".encode_utf16()),
            V::Bool(v) => out.extend(if *v { "true" } else { "false" }.encode_utf16()),
            V::Int(v) => out.extend(v.to_string().encode_utf16()),
            V::Float(v) => out.extend(float_string(*v).encode_utf16()),
            V::Str(v) => quote(v, out, limit)?,
            V::List(values) => {
                out.push(b'[' as u16);
                for (i, v) in values.iter().enumerate() {
                    if i > 0 {
                        out.push(b',' as u16);
                    }
                    write(v, out, limit)?;
                }
                out.push(b']' as u16);
            }
            V::Map(values) => {
                out.push(b'{' as u16);
                for (i, (k, v)) in values.iter().enumerate() {
                    if i > 0 {
                        out.push(b',' as u16);
                    }
                    quote(k, out, limit)?;
                    out.push(b':' as u16);
                    write(v, out, limit)?;
                }
                out.push(b'}' as u16);
            }
        }
        if out.len() > limit {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 크기 한도를 넘었습니다.",
            ));
        }
        Ok(())
    }
    let mut result = Vec::new();
    write(value, &mut result, limit)?;
    Ok(result.into())
}
fn quote(value: &[u16], out: &mut Vec<u16>, limit: usize) -> QResult<()> {
    out.push(b'"' as u16);
    let mut i = 0;
    while i < value.len() {
        let c = value[i];
        match c {
            8 => out.extend("\\b".encode_utf16()),
            9 => out.extend("\\t".encode_utf16()),
            10 => out.extend("\\n".encode_utf16()),
            12 => out.extend("\\f".encode_utf16()),
            13 => out.extend("\\r".encode_utf16()),
            34 => out.extend("\\\"".encode_utf16()),
            92 => out.extend("\\\\".encode_utf16()),
            0..=31 => escaped_unit(c, out),
            0xd800..=0xdbff
                if value
                    .get(i + 1)
                    .is_some_and(|v| (0xdc00..=0xdfff).contains(v)) =>
            {
                out.push(c);
                i += 1;
                out.push(value[i]);
            }
            0xd800..=0xdfff => escaped_unit(c, out),
            _ => out.push(c),
        }
        if out.len() > limit {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 크기 한도를 넘었습니다.",
            ));
        }
        i += 1;
    }
    out.push(b'"' as u16);
    Ok(())
}
fn escaped_unit(value: u16, out: &mut Vec<u16>) {
    const HEX: &[u8] = b"0123456789abcdef";
    out.extend([
        92,
        117,
        HEX[(value >> 12) as usize] as u16,
        HEX[((value >> 8) & 15) as usize] as u16,
        HEX[((value >> 4) & 15) as usize] as u16,
        HEX[(value & 15) as usize] as u16,
    ]);
}
fn float_string(value: f64) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() {
            "-0.0"
        } else {
            "0.0"
        }
        .to_owned();
    }
    let raw = Number::from_f64(value).expect("finite float").to_string();
    let negative = raw.starts_with('-');
    let unsigned = raw.trim_start_matches('-');
    let (mantissa, exponent) = unsigned
        .split_once(['e', 'E'])
        .map_or((unsigned, 0), |(m, e)| {
            (m, e.parse::<i32>().expect("float exponent"))
        });
    let before = mantissa.find('.').unwrap_or(mantissa.len()) as i32;
    let mut digits = mantissa.replace('.', "");
    let zeros = digits.bytes().take_while(|b| *b == b'0').count();
    digits.drain(..zeros);
    let point = before + exponent - zeros as i32;
    while digits.ends_with('0') && digits.len() > 1 {
        digits.pop();
    }
    let mut result = String::new();
    if negative {
        result.push('-');
    }
    if value.abs() >= 1e-6 && value.abs() < 1e21 {
        if point <= 0 {
            result.push_str("0.");
            result.extend(std::iter::repeat_n('0', (-point) as usize));
            result.push_str(&digits);
        } else if point as usize >= digits.len() {
            result.push_str(&digits);
            result.extend(std::iter::repeat_n('0', point as usize - digits.len()));
            result.push_str(".0");
        } else {
            result.push_str(&digits[..point as usize]);
            result.push('.');
            result.push_str(&digits[point as usize..]);
        }
    } else {
        result.push(digits.as_bytes()[0] as char);
        if digits.len() > 1 {
            result.push('.');
            result.push_str(&digits[1..]);
        }
        let exp = point - 1;
        result.push('e');
        if exp >= 0 {
            result.push('+');
        }
        result.push_str(&exp.to_string());
    }
    result
}

pub(super) fn unique_key(value: &V) -> Vec<u8> {
    fn write(v: &V, out: &mut Vec<u8>) {
        match v {
            V::Null => out.push(0),
            V::Bool(v) => {
                out.push(1);
                out.push(u8::from(*v));
            }
            V::Int(v) => {
                out.push(2);
                let negative = *v < 0;
                let value = v.unsigned_abs();
                out.push(u8::from(negative && value != 0));
                let shift = if value == 0 {
                    0
                } else {
                    value.trailing_zeros()
                };
                out.extend((value >> shift).to_be_bytes());
                out.extend((shift as i32).to_be_bytes());
            }
            V::Float(v) if v.fract() == 0.0 => {
                out.push(2);
                let bits = v.to_bits();
                let mut mantissa = bits & ((1u64 << 52) - 1);
                let exponent = ((bits >> 52) & 0x7ff) as i32;
                let mut shift = exponent - 1023 - 52;
                if exponent != 0 {
                    mantissa |= 1u64 << 52;
                } else {
                    shift = -1074;
                }
                if *v == 0.0 {
                    mantissa = 0;
                    shift = 0;
                } else {
                    let n = mantissa.trailing_zeros();
                    mantissa >>= n;
                    shift += n as i32;
                }
                out.push(u8::from(v.is_sign_negative() && *v != 0.0));
                out.extend(mantissa.to_be_bytes());
                out.extend(shift.to_be_bytes());
            }
            V::Float(v) => {
                out.push(3);
                out.extend(v.to_bits().to_be_bytes());
            }
            V::Str(v) => {
                out.push(4);
                out.extend(v.len().to_be_bytes());
                for c in v.iter() {
                    out.extend(c.to_be_bytes());
                }
            }
            V::List(v) => {
                out.push(5);
                out.extend(v.len().to_be_bytes());
                for child in v.iter() {
                    write(child, out);
                }
            }
            V::Map(v) => {
                out.push(6);
                out.extend(v.len().to_be_bytes());
                let mut values = v.iter().collect::<Vec<_>>();
                values.sort_by(|a, b| a.0.cmp(&b.0));
                for (k, v) in values {
                    write(&V::Str(k.clone()), out);
                    write(v, out);
                }
            }
        }
    }
    let mut out = Vec::new();
    write(value, &mut out);
    out
}

const MAX_NODES: usize = 200000;
const MAX_UNITS: usize = 2000000;
const MAX_WIRE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Default)]
pub(super) struct Entries {
    count: usize,
    bytes: usize,
}
impl Entries {
    pub fn item(&mut self, root: usize) {
        self.bytes += usize::from(self.count > 0) + digits(root);
        self.count += 1;
    }
}

#[derive(Clone, Default)]
pub(super) struct OutputMeter {
    nodes: usize,
    units: usize,
    bytes: usize,
}
fn digits(value: usize) -> usize {
    if value == 0 {
        1
    } else {
        value.ilog10() as usize + 1
    }
}
fn output_limit() -> crate::ApiError {
    error(
        "query_too_large",
        "Query response exceeds its resource limit",
    )
}
impl OutputMeter {
    fn check(&self) -> ApiResult<()> {
        if self.nodes > MAX_NODES || self.units > MAX_UNITS || self.wire_size() > MAX_WIRE_BYTES {
            Err(output_limit())
        } else {
            Ok(())
        }
    }
    pub fn wire_size(&self) -> usize {
        let wrapper = r#"{"encoding":"utf16-v1","payload":{"root":0,"nodes":[]}}"#.len();
        wrapper - 1
            + digits(self.nodes.saturating_sub(1))
            + self.bytes
            + self.nodes.saturating_sub(1)
    }
    fn node(&mut self, bytes: usize) -> ApiResult<usize> {
        let index = self.nodes;
        self.nodes += 1;
        self.bytes += bytes;
        self.check()?;
        Ok(index)
    }
    pub fn text(&mut self, units: &[u16]) -> ApiResult<usize> {
        self.string(units.iter().copied())
    }
    pub fn utf8_text(&mut self, value: &str) -> ApiResult<usize> {
        self.string(value.encode_utf16())
    }
    fn string(&mut self, units: impl Iterator<Item = u16>) -> ApiResult<usize> {
        let (mut count, mut bytes) = (0, 0);
        for unit in units {
            bytes += digits(unit as usize) + usize::from(count > 0);
            count += 1;
        }
        self.units += count;
        self.node(8 + bytes)
    }
    pub fn array(&mut self, entries: Entries) -> ApiResult<usize> {
        self.node(8 + entries.bytes)
    }
    pub fn object(&mut self, entries: Entries) -> ApiResult<usize> {
        self.node(8 + entries.bytes)
    }
    pub fn field(&mut self, entries: &mut Entries, key: &str, root: usize) -> ApiResult<()> {
        self.key(entries, key.encode_utf16(), root)
    }
    fn key(
        &mut self,
        entries: &mut Entries,
        units: impl Iterator<Item = u16>,
        root: usize,
    ) -> ApiResult<()> {
        let (mut count, mut bytes) = (0, 0);
        for unit in units {
            bytes += digits(unit as usize) + usize::from(count > 0);
            count += 1;
        }
        self.units += count;
        entries.bytes += usize::from(entries.count > 0) + 5 + bytes + digits(root);
        entries.count += 1;
        self.check()
    }
    pub fn value(&mut self, value: &V) -> ApiResult<usize> {
        self.visit(value, 0)
    }
    fn visit(&mut self, value: &V, depth: usize) -> ApiResult<usize> {
        if depth > 128 {
            return Err(output_limit());
        }
        match value {
            V::Null => self.node(4),
            V::Bool(value) => self.node(if *value { 4 } else { 5 }),
            V::Int(value) => self.node(value.to_string().len()),
            V::Float(value) => self.node(
                Number::from_f64(*value)
                    .ok_or_else(invalid)?
                    .to_string()
                    .len(),
            ),
            V::Str(value) => self.text(value),
            V::List(values) => {
                let mut entries = Entries::default();
                for value in values.iter() {
                    entries.item(self.visit(value, depth + 1)?);
                }
                self.array(entries)
            }
            V::Map(values) => {
                let mut entries = Entries::default();
                for (key, value) in values.iter() {
                    let root = self.visit(value, depth + 1)?;
                    self.key(&mut entries, key.iter().copied(), root)?;
                }
                self.object(entries)
            }
        }
    }
}

pub(super) fn decode(payload: &Value) -> ApiResult<V> {
    let object = payload.as_object().ok_or_else(invalid)?;
    if object.len() != 2 {
        return Err(invalid());
    }
    let nodes = object
        .get("nodes")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    if nodes.is_empty()
        || nodes.len() > MAX_NODES
        || object.get("root").and_then(Value::as_u64) != Some((nodes.len() - 1) as u64)
    {
        return Err(invalid());
    }
    let mut refs = vec![0u8; nodes.len()];
    let mut depths = vec![0usize; nodes.len()];
    let mut units = 0;
    for (i, node) in nodes.iter().enumerate() {
        let Some(node) = node.as_array() else {
            if !(node.is_null() || node.is_boolean() || node.is_number() && number(node).is_ok()) {
                return Err(invalid());
            }
            continue;
        };
        if node.len() != 2 {
            return Err(invalid());
        }
        match node[0].as_str() {
            Some("s") => {
                let value = units_value(&node[1])?;
                units += value.len();
            }
            Some("a") => {
                let children = node[1].as_array().ok_or_else(invalid)?;
                for child in children {
                    child_ref(child, i, &mut refs, &mut depths)?;
                }
            }
            Some("o") => {
                let entries = node[1].as_array().ok_or_else(invalid)?;
                let mut keys = BTreeSet::new();
                for entry in entries {
                    let entry = entry
                        .as_array()
                        .filter(|v| v.len() == 2)
                        .ok_or_else(invalid)?;
                    let key = units_value(&entry[0])?;
                    units += key.len();
                    if !keys.insert(key) {
                        return Err(invalid());
                    }
                    child_ref(&entry[1], i, &mut refs, &mut depths)?;
                }
            }
            _ => return Err(invalid()),
        }
        if units > MAX_UNITS || depths[i] > 128 {
            return Err(error(
                "request_limit",
                "Query input exceeds its resource limit",
            ));
        }
    }
    if refs.iter().take(nodes.len() - 1).any(|r| *r != 1) || refs[nodes.len() - 1] != 0 {
        return Err(invalid());
    }
    let mut built = Vec::<Option<V>>::with_capacity(nodes.len());
    for node in nodes {
        let value = if let Some(node) = node.as_array() {
            match node[0].as_str() {
                Some("s") => V::Str(units_value(&node[1])?.into()),
                Some("a") => V::list(node[1].as_array().ok_or_else(invalid)?.iter().map(|child| {
                    built[child.as_u64().expect("checked child") as usize]
                        .take()
                        .expect("tree child")
                })),
                Some("o") => V::Map(
                    node[1]
                        .as_array()
                        .ok_or_else(invalid)?
                        .iter()
                        .map(|entry| {
                            Ok((
                                units_value(&entry[0])?.into(),
                                built[entry[1].as_u64().expect("checked child") as usize]
                                    .take()
                                    .expect("tree child"),
                            ))
                        })
                        .collect::<ApiResult<Vec<_>>>()?
                        .into(),
                ),
                _ => return Err(invalid()),
            }
        } else if node.is_null() {
            V::Null
        } else if let Some(b) = node.as_bool() {
            V::Bool(b)
        } else {
            number(node)?
        };
        built.push(Some(value));
    }
    built.pop().flatten().ok_or_else(invalid)
}
fn child_ref(child: &Value, index: usize, refs: &mut [u8], depths: &mut [usize]) -> ApiResult<()> {
    let child = child
        .as_u64()
        .filter(|v| *v < index as u64)
        .ok_or_else(invalid)? as usize;
    refs[child] += 1;
    if refs[child] > 1 {
        return Err(invalid());
    }
    depths[index] = depths[index].max(depths[child] + 1);
    Ok(())
}
fn units_value(value: &Value) -> ApiResult<Vec<u16>> {
    value
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .map(|v| {
            v.as_u64()
                .and_then(|v| u16::try_from(v).ok())
                .ok_or_else(invalid)
        })
        .collect()
}
fn number(value: &Value) -> ApiResult<V> {
    let n = value.as_number().ok_or_else(invalid)?;
    if n.is_f64() {
        n.as_f64()
            .filter(|v| v.is_finite())
            .map(V::Float)
            .ok_or_else(invalid)
    } else {
        n.as_i64().map(V::Int).ok_or_else(invalid)
    }
}
pub(super) fn encode(value: &V) -> ApiResult<Value> {
    OutputMeter::default().value(value)?;
    fn visit(
        value: &V,
        depth: usize,
        nodes: &mut Vec<Value>,
        units: &mut usize,
    ) -> ApiResult<usize> {
        if depth > 128 || nodes.len() >= MAX_NODES {
            return Err(error(
                "result_limit",
                "Query response exceeds its resource limit",
            ));
        }
        let node = match value {
            V::Null => Value::Null,
            V::Bool(v) => Value::Bool(*v),
            V::Int(v) => json!(v),
            V::Float(v) => Number::from_f64(*v)
                .map(Value::Number)
                .ok_or_else(invalid)?,
            V::Str(v) => {
                *units += v.len();
                json!(["s", v.as_ref()])
            }
            V::List(values) => {
                let mut children = Vec::new();
                for value in values.iter() {
                    children.push(visit(value, depth + 1, nodes, units)?);
                }
                json!(["a", children])
            }
            V::Map(values) => {
                let mut entries = Vec::new();
                for (k, v) in values.iter() {
                    *units += k.len();
                    let child = visit(v, depth + 1, nodes, units)?;
                    entries.push(json!([k.as_ref(), child]));
                }
                json!(["o", entries])
            }
        };
        if *units > MAX_UNITS || nodes.len() >= MAX_NODES {
            return Err(error(
                "result_limit",
                "Query response exceeds its resource limit",
            ));
        }
        let index = nodes.len();
        nodes.push(node);
        Ok(index)
    }
    let mut nodes = Vec::new();
    let root = visit(value, 0, &mut nodes, &mut 0)?;
    let result = json!({"encoding":"utf16-v1","payload":{"root":root,"nodes":nodes}});
    if result.to_string().len() > 8 * 1024 * 1024 {
        return Err(error(
            "result_limit",
            "Query response exceeds its resource limit",
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod output_limit_tests {
    use super::*;

    #[test]
    fn output_units_accumulate_before_another_value_is_retained() {
        let value = V::text(vec![97; 1_000_000]);
        let mut meter = OutputMeter::default();
        assert!(meter.value(&value).is_ok());
        assert!(meter.value(&value).is_ok());
        assert_eq!(
            meter.value(&V::s("x")).err().unwrap().code,
            "query_too_large"
        );
    }

    #[test]
    fn output_node_budget_accumulates_across_fragments() {
        let mut meter = OutputMeter::default();
        for _ in 0..MAX_NODES {
            assert!(meter.value(&V::Null).is_ok());
        }
        assert_eq!(meter.value(&V::Null).err().unwrap().code, "query_too_large");
    }

    #[test]
    fn wire_measure_matches_the_actual_flat_serializer() {
        let value = V::object([
            (
                "value",
                V::list([V::Int(-9), V::Float(-0.0), V::text(vec![0, 0xd800, 0xffff])]),
            ),
            ("empty", V::object([])),
        ]);
        let mut meter = OutputMeter::default();
        assert!(meter.value(&value).is_ok());
        let encoded = encode(&value).ok().unwrap();
        assert_eq!(meter.wire_size(), encoded.to_string().len());
    }
}
