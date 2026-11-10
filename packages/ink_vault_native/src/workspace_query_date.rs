use super::workspace_query_value::{Fault, Num, QResult, V, text, utf8};
use regex::Regex;
use std::sync::OnceLock;

const SECOND: i64 = 1_000_000;
const DAY: i64 = 86_400 * SECOND;
const LIMIT: i128 = 8_640_000_000_000_000_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(super) struct Date(pub i64);
pub(super) struct Range {
    pub start: Date,
    pub end: Option<Date>,
    pub all_day: bool,
}

pub(super) fn range(value: &V) -> QResult<Range> {
    let start = if matches!(value, V::Str(_)) {
        value
    } else {
        let start = value.get("start");
        if start.null() {
            value.get("dateISO")
        } else {
            start
        }
    };
    let start_text = start.string().ok_or_else(invalid_date)?;
    let first =
        parse(&utf8(start_text).map_err(|_| invalid_date())?, false).ok_or_else(invalid_date)?;
    let end = value.get("end");
    let last = if end.null() {
        None
    } else {
        Some(parse(&end.utf8().ok_or_else(invalid_date)?, false).ok_or_else(invalid_date)?)
    };
    if last.is_some_and(|last| last < first)
        || matches!(value, V::Map(_))
            && !value.get("timeZone").null()
            && !matches!(value.get("timeZone"), V::Str(_))
    {
        return Err(invalid_date());
    }
    Ok(Range {
        start: first,
        end: last,
        all_day: !start_text.contains(&(b'T' as u16)),
    })
}
pub(super) fn date(value: &V) -> QResult<Date> {
    Ok(range(value)?.start)
}
fn invalid_date() -> Fault {
    Fault::message("type_error", "올바른 ISO 날짜가 필요합니다.")
}

pub(super) fn parse(value: &str, clock: bool) -> Option<Date> {
    static ISO: OnceLock<Regex> = OnceLock::new();
    static CLOCK: OnceLock<Regex> = OnceLock::new();
    let pattern = if clock {
        CLOCK.get_or_init(||Regex::new(r"^([+-][0-9]{6}|-?[0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,6}))?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$").expect("clock pattern"))
    } else {
        ISO.get_or_init(||Regex::new(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,6}))?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$").expect("date pattern"))
    };
    let captures = pattern.captures(value)?;
    let part = |i| {
        captures
            .get(i)
            .map_or(Some(0), |v| v.as_str().parse::<i64>().ok())
    };
    let (year, month, day, hour, minute, second) =
        (part(1)?, part(2)?, part(3)?, part(4)?, part(5)?, part(6)?);
    if !(1..=12).contains(&month)
        || day < 1
        || day > month_days(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }
    let micro = captures.get(7).map_or(Some(0), |v| {
        format!("{:0<6}", v.as_str()).parse::<i64>().ok()
    })?;
    let offset = if let Some(zone) = captures.get(8).map(|v| v.as_str()).filter(|v| *v != "Z") {
        let hours = zone[1..3].parse::<i64>().ok()?;
        let minutes = zone[4..6].parse::<i64>().ok()?;
        if hours > 23 || minutes > 59 {
            return None;
        }
        (if zone.starts_with('-') { -1 } else { 1 }) * (hours * 60 + minutes) * 60 * SECOND
    } else {
        0
    };
    let micros = days_from_civil(year, month, day) as i128 * DAY as i128
        + (hour * 3600 + minute * 60 + second) as i128 * SECOND as i128
        + micro as i128
        - offset as i128;
    from_micros(micros)
}
fn from_micros(micros: i128) -> Option<Date> {
    if !(-LIMIT..=LIMIT).contains(&micros) {
        None
    } else {
        Some(Date(micros as i64))
    }
}
pub(super) fn month_days(year: i64, month: i64) -> i64 {
    match month {
        2 => {
            if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                29
            } else {
                28
            }
        }
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}
fn days_from_civil(mut year: i64, month: i64, day: i64) -> i64 {
    year -= i64::from(month <= 2);
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    era * 146097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719468
}
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}
impl Date {
    pub fn parts(self) -> (i64, i64, i64, i64, i64, i64, i64) {
        let days = self.0.div_euclid(DAY);
        let t = self.0.rem_euclid(DAY);
        let (y, m, d) = civil_from_days(days);
        (
            y,
            m,
            d,
            t / SECOND / 3600,
            t / SECOND / 60 % 60,
            t / SECOND % 60,
            t % SECOND,
        )
    }
    pub fn iso(self) -> String {
        let (y, m, d, h, min, s, u) = self.parts();
        let year = if (-9999..=9999).contains(&y) {
            if y < 0 {
                format!("-{:04}", -y)
            } else {
                format!("{y:04}")
            }
        } else if y < 0 {
            format!("-{:06}", -y)
        } else {
            format!("+{y:06}")
        };
        let frac = if u % 1000 == 0 {
            format!("{:03}", u / 1000)
        } else {
            format!("{u:06}")
        };
        format!("{year}-{m:02}-{d:02}T{h:02}:{min:02}:{s:02}.{frac}Z")
    }
    pub fn day(self) -> String {
        let (y, m, d, _, _, _, _) = self.parts();
        let year = y.to_string();
        format!("{:0>4}-{m:02}-{d:02}", year)
    }
    pub fn weekday(self) -> i64 {
        (self.0.div_euclid(DAY) + 3).rem_euclid(7) + 1
    }
    pub fn add(self, amount: Num, unit: &str) -> QResult<Date> {
        let number = amount.f64();
        if !(-1000000.0..=1000000.0).contains(&number) || number.fract() != 0.0 {
            return Err(Fault::message(
                "argument_error",
                "날짜 이동에는 한도 안의 정수가 필요합니다.",
            ));
        }
        let n = number as i64;
        let result = match unit.to_lowercase().as_str() {
            "seconds" => from_micros(self.0 as i128 + n as i128 * SECOND as i128),
            "minutes" => from_micros(self.0 as i128 + n as i128 * 60 * SECOND as i128),
            "hours" => from_micros(self.0 as i128 + n as i128 * 3600 * SECOND as i128),
            "days" => from_micros(self.0 as i128 + n as i128 * DAY as i128),
            "weeks" => from_micros(self.0 as i128 + n as i128 * 7 * DAY as i128),
            "months" | "years" => {
                let (y, m, d, h, min, s, u) = self.parts();
                let total = y * 12 + m - 1
                    + if unit.eq_ignore_ascii_case("years") {
                        n * 12
                    } else {
                        n
                    };
                let year = total.div_euclid(12);
                let month = total.rem_euclid(12) + 1;
                let day = d.min(month_days(year, month));
                from_micros(
                    days_from_civil(year, month, day) as i128 * DAY as i128
                        + (h * 3600 + min * 60 + s) as i128 * SECOND as i128
                        + u as i128,
                )
            }
            _ => {
                return Err(Fault::message(
                    "argument_error",
                    "지원하지 않는 날짜 단위입니다.",
                ));
            }
        };
        result.ok_or_else(|| Fault::message("numeric_overflow", "날짜 범위를 넘었습니다."))
    }
    pub fn between(self, other: Date, unit: &str) -> QResult<i64> {
        let micros = self.0 as i128 - other.0 as i128;
        let divisor = match unit.to_lowercase().as_str() {
            "seconds" => SECOND,
            "minutes" => 60 * SECOND,
            "hours" => 3600 * SECOND,
            "days" => DAY,
            "weeks" => 7 * DAY,
            _ => {
                return Err(Fault::message(
                    "argument_error",
                    "지원하지 않는 날짜 단위입니다.",
                ));
            }
        };
        i64::try_from(micros / divisor as i128)
            .map_err(|_| Fault::message("numeric_overflow", "날짜 범위를 넘었습니다."))
    }
    pub fn format(self, pattern: &[u16]) -> QResult<V> {
        if pattern.len() > 128 {
            return Err(Fault::new("argument_error"));
        }
        let (y, m, d, h, min, s, _) = self.parts();
        let mut result = pattern.to_vec();
        let year = format!("{:0>4}", y.to_string());
        for (token, value) in [
            ("YYYY", year),
            ("MM", format!("{m:02}")),
            ("DD", format!("{d:02}")),
            ("HH", format!("{h:02}")),
            ("mm", format!("{min:02}")),
            ("ss", format!("{s:02}")),
        ] {
            let token = text(token);
            let replacement = text(&value);
            let mut next = Vec::new();
            let mut i = 0;
            while i < result.len() {
                if result[i..].starts_with(&token) {
                    next.extend(replacement.iter().copied());
                    i += token.len();
                } else {
                    next.push(result[i]);
                    i += 1;
                }
            }
            result = next;
        }
        Ok(V::text(result))
    }
}
