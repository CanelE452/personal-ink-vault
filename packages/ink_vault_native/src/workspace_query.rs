use super::workspace_query_date::{self as dates, Date};
use super::workspace_query_value::{
    self as values, Entries, Fault, Num, OutputMeter, QResult, Text, V, bounded, case_map, compare,
    empty, equal, find, json_text, json_text_limited, scalar_len, stringify, text, text_eq, trim,
    unique_key,
};
use crate::{ApiResult, error, invalid};
use serde_json::{Map, Value};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

#[derive(Clone)]
struct Property {
    id: String,
    name: Text,
    kind: String,
    config: V,
}
#[derive(Clone)]
struct Row {
    id: String,
    values: V,
    archived: bool,
}
struct Database {
    id: String,
    properties: Vec<Property>,
    rows: Vec<Row>,
}

fn id(value: &V) -> ApiResult<String> {
    let value = value.utf8().ok_or_else(invalid)?;
    if value.len() != 36
        || !value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
    {
        return Err(invalid());
    }
    Ok(value)
}
fn object_or_empty(value: &V) -> ApiResult<V> {
    if value.null() {
        Ok(V::Map(Vec::new().into()))
    } else if matches!(value, V::Map(_)) {
        Ok(value.clone())
    } else {
        Err(invalid())
    }
}
fn array_or_empty(value: &V) -> ApiResult<&[V]> {
    if value.null() {
        Ok(&[])
    } else {
        value.array().ok_or_else(invalid)
    }
}
impl Database {
    fn parse(value: &V) -> ApiResult<Self> {
        if !matches!(value, V::Map(_))
            || !value.get("schemaVersion").null() && value.get("schemaVersion").int() != Some(1)
        {
            return Err(invalid());
        }
        let mut properties = Vec::new();
        let mut known = BTreeSet::new();
        for raw in array_or_empty(value.get("properties"))? {
            if !matches!(raw, V::Map(_)) {
                return Err(invalid());
            }
            let identity = id(raw.get("id"))?;
            if !known.insert(identity.clone()) {
                return Err(invalid());
            }
            let name = raw.get("name").string().cloned().ok_or_else(invalid)?;
            let kind = raw.get("type").string().ok_or_else(invalid)?;
            if trim(&name).is_empty() || trim(kind).is_empty() {
                return Err(invalid());
            }
            properties.push(Property {
                id: identity,
                name,
                kind: control_string(kind),
                config: object_or_empty(raw.get("config"))?,
            });
        }
        let mut rows = Vec::new();
        known.clear();
        for raw in array_or_empty(value.get("rows"))? {
            if !matches!(raw, V::Map(_)) {
                return Err(invalid());
            }
            let identity = id(raw.get("id"))?;
            if !known.insert(identity.clone()) {
                return Err(invalid());
            }
            let values = object_or_empty(raw.get("values"))?;
            let archived = if raw.get("archived").null() {
                false
            } else {
                raw.get("archived").boolean().ok_or_else(invalid)?
            };
            for property in &properties {
                validate_value(property, values.get(&property.id))?;
            }
            rows.push(Row {
                id: identity,
                values,
                archived,
            });
        }
        Ok(Self {
            id: id(value.get("id"))?,
            properties,
            rows,
        })
    }
}
fn validate_value(property: &Property, value: &V) -> ApiResult<()> {
    if value.null() {
        return Ok(());
    }
    let valid = match property.kind.as_str() {
        "title" | "text" | "phone" | "url" | "email" => matches!(value, V::Str(_)),
        "number" => matches!(value, V::Int(_) | V::Float(_)),
        "checkbox" => matches!(value, V::Bool(_)),
        "date" => dates::range(value).is_ok(),
        "formula" | "rollup" => false,
        "status" | "select" => valid_option(property, value),
        "multiSelect" => value.array().is_some_and(|items| {
            let mut seen = BTreeSet::new();
            items.iter().all(|v| {
                v.string().is_some_and(|v| seen.insert(v.clone())) && valid_option(property, v)
            })
        }),
        "relation" => {
            let refs = if let V::List(refs) = value {
                refs.as_ref()
            } else {
                std::slice::from_ref(value)
            };
            let mut seen = BTreeSet::new();
            refs.iter().all(|v| {
                let (Ok(db), Ok(row)) = (id(v.get("databaseId")), id(v.get("rowId"))) else {
                    return false;
                };
                let target = property.config.get("databaseId");
                (target.null() || target.utf8().as_deref() == Some(db.as_str()))
                    && seen.insert((db, row))
            })
        }
        "people" => value.array().is_some_and(|v| {
            v.iter().all(|person| {
                matches!(person, V::Str(_))
                    || matches!(person, V::Map(_))
                        && person
                            .get("id")
                            .string()
                            .is_some_and(|v| !trim(v).is_empty())
                        && (person.get("name").null() || matches!(person.get("name"), V::Str(_)))
            })
        }),
        "files" => value.array().is_some_and(|v| {
            v.iter().all(|file| {
                matches!(file, V::Map(_))
                    && file
                        .get("name")
                        .string()
                        .is_some_and(|v| !trim(v).is_empty())
                    && (file.get("url").null() || matches!(file.get("url"), V::Str(_)))
            })
        }),
        _ => true,
    };
    if valid { Ok(()) } else { Err(invalid()) }
}
fn valid_option(property: &Property, value: &V) -> bool {
    let Some(value) = value.string() else {
        return false;
    };
    let options = property.config.get("options");
    if options.null() || value.is_empty() {
        return true;
    }
    options.array().is_some_and(|options| {
        options.iter().any(|o| {
            o.string() == Some(value)
                || o.get("id").string() == Some(value)
                || o.get("name").string() == Some(value)
        })
    })
}

pub(super) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 4
        || request.get("op").and_then(Value::as_str) != Some("workspace_query")
        || request.get("schemaVersion").and_then(Value::as_i64) != Some(1)
        || request.get("encoding").and_then(Value::as_str) != Some("utf16-v1")
    {
        return Err(invalid());
    }
    let logical = values::decode(request.get("payload").ok_or_else(invalid)?)?;
    let fields = logical.map().ok_or_else(invalid)?;
    for (key, _) in fields {
        if ![
            "op",
            "schemaVersion",
            "database",
            "databases",
            "capturedAtUtc",
            "maxDepth",
            "budget",
            "operations",
        ]
        .iter()
        .any(|v| text_eq(key, v))
        {
            return Err(invalid());
        }
    }
    if logical.get("op").utf8().as_deref() != Some("workspace_query")
        || logical.get("schemaVersion").int() != Some(1)
    {
        return Err(invalid());
    }
    let max_depth = if logical.get("maxDepth").null() {
        32
    } else {
        logical.get("maxDepth").int().ok_or_else(invalid)?
    };
    let budget = if logical.get("budget").null() {
        10000
    } else {
        logical.get("budget").int().ok_or_else(invalid)?
    };
    if !(1..=128).contains(&max_depth) || !(1..=1000000).contains(&budget) {
        return Err(invalid());
    }
    let clock = if logical.get("capturedAtUtc").null() {
        None
    } else {
        Some(
            dates::parse(
                &logical.get("capturedAtUtc").utf8().ok_or_else(invalid)?,
                true,
            )
            .ok_or_else(invalid)?,
        )
    };
    let operations = logical
        .get("operations")
        .array()
        .filter(|v| v.len() <= 512)
        .ok_or_else(invalid)?;
    let mut databases = vec![Database::parse(logical.get("database"))?];
    let mut identities = BTreeSet::from([databases[0].id.clone()]);
    for database in array_or_empty(logical.get("databases"))? {
        let db = Database::parse(database)?;
        if !identities.insert(db.id.clone()) {
            return Err(invalid());
        }
        databases.push(db);
    }
    let mut session = Session {
        databases,
        clock,
        max_depth: max_depth as usize,
        remaining: budget,
        cache: BTreeMap::new(),
        parsed: BTreeMap::new(),
        active: Vec::new(),
        errors: Vec::new(),
        retained: BTreeSet::new(),
        retained_units: 0,
        retained_nodes: 0,
        normalized: BTreeMap::new(),
        normalization_exhausted: false,
    };
    let mut results = Vec::new();
    let mut output = OutputGuard::default();
    let mut selections = BTreeMap::<usize, Vec<usize>>::new();
    let mut value_cells = 0usize;
    for (i, operation) in operations.iter().enumerate() {
        let kind = operation.get("type").utf8().ok_or_else(invalid)?;
        let result = match kind.as_str() {
            "value" => {
                operation_keys(operation, &["type", "rowId", "propertyId"])?;
                value_cells += 1;
                session.value(
                    0,
                    &required_text(operation.get("rowId"))?,
                    &required_text(operation.get("propertyId"))?,
                )
            }
            "apply" => {
                operation_keys(operation, &["type", "view"])?;
                let view = required_view(operation.get("view"))?;
                let selected = session.project(&view).map_err(fatal_fault)?;
                let mut measured = output.meter.clone();
                let root = selected.measure(&mut measured, &session)?;
                output.check_root(measured, root, &session.errors, session.remaining)?;
                selections.insert(i, selected.rows.clone());
                selected.value(&session)
            }
            "values" => {
                operation_keys(operation, &["type", "from", "propertyIds"])?;
                let rows = selection(operation.get("from"), &selections)?;
                let properties = operation
                    .get("propertyIds")
                    .array()
                    .ok_or_else(invalid)?
                    .iter()
                    .map(required_text)
                    .collect::<ApiResult<Vec<_>>>()?;
                value_cells = value_cells
                    .checked_add(
                        rows.len()
                            .checked_mul(properties.len())
                            .ok_or_else(invalid)?,
                    )
                    .ok_or_else(invalid)?;
                if value_cells > 10000 {
                    return Err(error(
                        "request_limit",
                        "Query value plan exceeds its cell limit",
                    ));
                }
                let mut values = Vec::new();
                for row in rows {
                    let row_id = text(&session.databases[0].rows[row].id);
                    let mut cells = Vec::new();
                    for property in &properties {
                        let value = session.value(0, &row_id, property);
                        cells.push(value.with("propertyId", V::Str(property.clone())));
                    }
                    values.push(V::object([
                        ("rowId", V::Str(row_id)),
                        ("values", V::list(cells)),
                    ]));
                }
                V::list(values)
            }
            "aggregate" => {
                operation_keys(
                    operation,
                    &[
                        "type",
                        "propertyId",
                        "calculation",
                        "rowIds",
                        "from",
                        "view",
                    ],
                )?;
                let property = required_text(operation.get("propertyId"))?;
                let calculation = optional_utf8(operation.get("calculation"), "sum")?;
                let selectors = ["rowIds", "from", "view"]
                    .iter()
                    .filter(|key| !operation.get(key).null())
                    .count();
                if selectors > 1 {
                    return Err(invalid());
                }
                let rows = if !operation.get("rowIds").null() {
                    Some(
                        operation
                            .get("rowIds")
                            .array()
                            .ok_or_else(invalid)?
                            .iter()
                            .map(required_text)
                            .collect::<ApiResult<Vec<_>>>()?,
                    )
                } else if !operation.get("from").null() {
                    Some(
                        selection(operation.get("from"), &selections)?
                            .iter()
                            .map(|index| text(&session.databases[0].rows[*index].id))
                            .collect(),
                    )
                } else {
                    None
                };
                let view = if operation.get("view").null() {
                    None
                } else {
                    Some(required_view(operation.get("view"))?)
                };
                let result =
                    session.aggregate_rows(&property, &calculation, rows.as_deref(), view.as_ref());
                session.calculation_result(result)
            }
            "calendar" => {
                operation_keys(operation, &["type", "propertyId", "view"])?;
                let property = required_text(operation.get("propertyId"))?;
                let view = if operation.get("view").null() {
                    None
                } else {
                    Some(required_view(operation.get("view"))?)
                };
                session
                    .calendar(&property, view.as_ref(), &output)
                    .map_err(fatal_fault)?
            }
            "chart" => {
                operation_keys(
                    operation,
                    &["type", "groupBy", "valuePropertyId", "calculation", "view"],
                )?;
                let group = required_text(operation.get("groupBy"))?;
                let property = if operation.get("valuePropertyId").null() {
                    None
                } else {
                    Some(required_text(operation.get("valuePropertyId"))?)
                };
                let calculation = optional_utf8(operation.get("calculation"), "count")?;
                let view = if operation.get("view").null() {
                    None
                } else {
                    Some(required_view(operation.get("view"))?)
                };
                let result = session.chart(
                    &group,
                    property.as_ref(),
                    &calculation,
                    view.as_ref(),
                    &output,
                );
                match result {
                    Ok(v) => v,
                    Err(fault) if fault.code == "query_too_large" => {
                        return Err(fatal_fault(fault));
                    }
                    Err(fault) => {
                        session.record(fault);
                        V::list([])
                    }
                }
            }
            _ => return Err(invalid()),
        };
        if value_cells > 10000 {
            return Err(error(
                "request_limit",
                "Query value plan exceeds its cell limit",
            ));
        }
        output.retain(&result, &session.errors, session.remaining)?;
        results.push(result);
    }
    values::encode(&V::object([
        ("results", V::list(results)),
        ("errors", V::list(session.errors.iter().map(Fault::value))),
        ("remainingBudget", V::Int(session.remaining)),
    ]))
}
fn fatal_fault(fault: Fault) -> crate::ApiError {
    error(fault.code, fault.message)
}
fn required_text(value: &V) -> ApiResult<Text> {
    value.string().cloned().ok_or_else(invalid)
}
fn control_string(value: &[u16]) -> String {
    String::from_utf16(value).unwrap_or_else(|_| "\0".to_owned())
}
fn optional_utf8(value: &V, default: &str) -> ApiResult<String> {
    if value.null() {
        Ok(default.to_owned())
    } else {
        value
            .string()
            .map(|value| control_string(value))
            .ok_or_else(invalid)
    }
}
fn operation_keys(value: &V, allowed: &[&str]) -> ApiResult<()> {
    let fields = value.map().ok_or_else(invalid)?;
    if fields
        .iter()
        .any(|(k, _)| !allowed.iter().any(|v| text_eq(k, v)))
    {
        Err(invalid())
    } else {
        Ok(())
    }
}
fn required_view(value: &V) -> ApiResult<V> {
    if !matches!(value, V::Map(_))
        || !value.get("filter").null() && !matches!(value.get("filter"), V::Map(_))
        || !value.get("groupBy").null() && !matches!(value.get("groupBy"), V::Str(_))
    {
        return Err(invalid());
    }
    for sort in array_or_empty(value.get("sorts"))? {
        if !matches!(sort, V::Map(_)) {
            return Err(invalid());
        }
    }
    Ok(value.clone())
}
fn selection(value: &V, selections: &BTreeMap<usize, Vec<usize>>) -> ApiResult<Vec<usize>> {
    let index = value.int().filter(|v| *v >= 0).ok_or_else(invalid)? as usize;
    selections.get(&index).cloned().ok_or_else(invalid)
}

struct Projection {
    rows: Vec<usize>,
    groups: Vec<(Text, Vec<usize>)>,
    error_count: usize,
}
impl Projection {
    fn measure(&self, meter: &mut OutputMeter, session: &Session) -> ApiResult<usize> {
        let mut result = Entries::default();
        let row_ids = measure_rows(meter, self.rows.iter().copied(), session)?;
        meter.field(&mut result, "rowIds", row_ids)?;
        let mut groups = Entries::default();
        for (key, rows) in &self.groups {
            let mut group = Entries::default();
            let key = meter.text(key)?;
            meter.field(&mut group, "key", key)?;
            let rows = measure_rows(meter, rows.iter().copied(), session)?;
            meter.field(&mut group, "rowIds", rows)?;
            groups.item(meter.object(group)?);
        }
        let groups = meter.array(groups)?;
        meter.field(&mut result, "groups", groups)?;
        let errors = measure_errors(meter, &session.errors[..self.error_count])?;
        meter.field(&mut result, "errors", errors)?;
        meter.object(result)
    }
    fn value(&self, session: &Session) -> V {
        V::object([
            (
                "rowIds",
                V::list(
                    self.rows
                        .iter()
                        .map(|i| V::s(&session.databases[0].rows[*i].id)),
                ),
            ),
            (
                "groups",
                V::list(self.groups.iter().map(|(key, rows)| {
                    V::object([
                        ("key", V::Str(key.clone())),
                        (
                            "rowIds",
                            V::list(rows.iter().map(|i| V::s(&session.databases[0].rows[*i].id))),
                        ),
                    ])
                })),
            ),
            (
                "errors",
                V::list(session.errors[..self.error_count].iter().map(Fault::value)),
            ),
        ])
    }
}
fn measure_rows(
    meter: &mut OutputMeter,
    rows: impl Iterator<Item = usize>,
    session: &Session,
) -> ApiResult<usize> {
    let mut entries = Entries::default();
    for row in rows {
        entries.item(meter.utf8_text(&session.databases[0].rows[row].id)?);
    }
    meter.array(entries)
}
fn measure_errors(meter: &mut OutputMeter, errors: &[Fault]) -> ApiResult<usize> {
    let mut entries = Entries::default();
    for error in errors {
        let mut fields = Entries::default();
        let code = meter.utf8_text(error.code)?;
        meter.field(&mut fields, "code", code)?;
        let message = meter.utf8_text(error.message)?;
        meter.field(&mut fields, "message", message)?;
        let mut path = Entries::default();
        for item in &error.path {
            path.item(meter.utf8_text(item)?);
        }
        let path = meter.array(path)?;
        meter.field(&mut fields, "path", path)?;
        entries.item(meter.object(fields)?);
    }
    meter.array(entries)
}
#[derive(Default)]
struct OutputGuard {
    meter: OutputMeter,
    roots: Entries,
}
impl OutputGuard {
    fn check_root(
        &self,
        mut meter: OutputMeter,
        root: usize,
        errors: &[Fault],
        remaining: i64,
    ) -> ApiResult<()> {
        let mut roots = self.roots;
        roots.item(root);
        let mut response = Entries::default();
        let results = meter.array(roots)?;
        meter.field(&mut response, "results", results)?;
        let errors = measure_errors(&mut meter, errors)?;
        meter.field(&mut response, "errors", errors)?;
        let remaining = meter.value(&V::Int(remaining))?;
        meter.field(&mut response, "remainingBudget", remaining)?;
        meter.object(response)?;
        Ok(())
    }
    fn check_array(
        &self,
        meter: &OutputMeter,
        entries: Entries,
        errors: &[Fault],
        remaining: i64,
    ) -> ApiResult<()> {
        let mut meter = meter.clone();
        let root = meter.array(entries)?;
        self.check_root(meter, root, errors, remaining)
    }
    fn retain(&mut self, value: &V, errors: &[Fault], remaining: i64) -> ApiResult<()> {
        let mut meter = self.meter.clone();
        let root = meter.value(value)?;
        self.check_root(meter.clone(), root, errors, remaining)?;
        self.roots.item(root);
        self.meter = meter;
        Ok(())
    }
}
fn output_fault(error: crate::ApiError) -> Fault {
    Fault::message(error.code, error.message)
}
struct Session {
    databases: Vec<Database>,
    clock: Option<Date>,
    max_depth: usize,
    remaining: i64,
    cache: BTreeMap<String, V>,
    parsed: BTreeMap<Text, Arc<Ast>>,
    active: Vec<String>,
    errors: Vec<Fault>,
    retained: BTreeSet<(u8, usize)>,
    retained_units: usize,
    retained_nodes: usize,
    normalized: BTreeMap<(u8, SourceKey), (V, Text)>,
    normalization_exhausted: bool,
}
#[derive(Eq, PartialEq, Ord, PartialOrd)]
enum SourceKey {
    Null,
    Bool(bool),
    Int(i64),
    Float(u64),
    Text(usize),
    List(usize),
    Map(usize),
}
fn source_key(value: &V) -> SourceKey {
    match value {
        V::Null => SourceKey::Null,
        V::Bool(value) => SourceKey::Bool(*value),
        V::Int(value) => SourceKey::Int(*value),
        V::Float(value) => SourceKey::Float(value.to_bits()),
        V::Str(value) => SourceKey::Text(Arc::as_ptr(value) as *const u16 as usize),
        V::List(value) => SourceKey::List(Arc::as_ptr(value) as *const V as usize),
        V::Map(value) => SourceKey::Map(Arc::as_ptr(value) as *const (Text, V) as usize),
    }
}
fn normalization_limit() -> Fault {
    Fault::message("query_too_large", "정렬·그룹 키의 보관 한도를 넘었습니다.")
}
impl Session {
    fn normalized(&mut self, value: &V, kind: u8) -> QResult<Text> {
        let identity = (kind, source_key(value));
        if let Some((_, key)) = self.normalized.get(&identity) {
            return Ok(key.clone());
        }
        if self.normalization_exhausted || self.retained_nodes >= 200000 {
            self.normalization_exhausted = true;
            return Err(normalization_limit());
        }
        let remaining = 4000000usize.saturating_sub(self.retained_units);
        let result = (|| {
            let key = match kind {
                0 => case_map(&value.text_value()?, false),
                1 => json_text_limited(value, remaining).map_err(|fault| {
                    if fault.code == "result_limit" {
                        normalization_limit()
                    } else {
                        fault
                    }
                })?,
                2 => text(&dates::date(value)?.day()),
                _ => group_key(value)?,
            };
            let already_retained = self
                .retained
                .contains(&(0, Arc::as_ptr(&key) as *const u16 as usize));
            if !already_retained && key.len() > remaining {
                return Err(normalization_limit());
            }
            self.retain(&V::Str(key.clone()))
                .map_err(|_| normalization_limit())?;
            self.normalized
                .insert(identity, (value.clone(), key.clone()));
            Ok(key)
        })();
        if result
            .as_ref()
            .is_err_and(|fault: &Fault| fault.code == "query_too_large")
        {
            self.normalization_exhausted = true;
        }
        result
    }
    fn group_membership(&mut self) -> QResult<()> {
        if self.normalization_exhausted || self.retained_nodes >= 200000 {
            self.normalization_exhausted = true;
            return Err(normalization_limit());
        }
        self.retained_nodes += 1;
        Ok(())
    }
    fn tick(&mut self) -> QResult<()> {
        self.remaining -= 1;
        if self.remaining < 0 {
            Err(Fault::message(
                "budget_exceeded",
                "계산 작업 한도를 넘었습니다.",
            ))
        } else {
            Ok(())
        }
    }
    fn record(&mut self, fault: Fault) {
        if !self
            .errors
            .iter()
            .any(|e| e.code == fault.code && e.path == fault.path)
        {
            self.errors.push(fault);
        }
    }
    fn calculation_result(&mut self, result: QResult<V>) -> V {
        match result {
            Ok(value) => V::object([("value", value)]),
            Err(fault) => {
                self.record(fault.clone());
                V::object([("value", V::Null), ("error", fault.value())])
            }
        }
    }
    fn row(&self, db: usize, id: &Text, relation: bool) -> QResult<usize> {
        self.databases[db]
            .rows
            .iter()
            .position(|r| text_eq(id, &r.id) && !r.archived)
            .ok_or_else(|| {
                Fault::message(
                    if relation {
                        "missing_relation"
                    } else {
                        "missing_row"
                    },
                    "참조한 항목이 없거나 보관 처리되었습니다.",
                )
            })
    }
    fn property(&self, db: usize, id: &Text) -> QResult<Property> {
        if let Some(p) = self.databases[db]
            .properties
            .iter()
            .find(|p| text_eq(id, &p.id))
        {
            return Ok(p.clone());
        }
        let mut names = self.databases[db]
            .properties
            .iter()
            .filter(|p| p.name == *id);
        let first = names
            .next()
            .ok_or_else(|| Fault::message("missing_property", "참조한 속성을 찾지 못했습니다."))?;
        if names.next().is_some() {
            return Err(Fault::message(
                "ambiguous_property",
                "같은 이름의 속성이 여러 개입니다. 속성 ID를 사용해 주세요.",
            ));
        }
        Ok(first.clone())
    }
    fn value(&mut self, db: usize, row: &Text, property: &Text) -> V {
        let result = self
            .row(db, row, false)
            .and_then(|row| self.read(db, row, property));
        self.calculation_result(result)
    }
    fn read(&mut self, db: usize, row: usize, property: &Text) -> QResult<V> {
        self.tick()?;
        let property = self.property(db, property)?;
        let key = format!(
            "{}/{}/{}",
            self.databases[db].id, self.databases[db].rows[row].id, property.id
        );
        if let Some(value) = self.cache.get(&key) {
            return Ok(value.clone());
        }
        if self.active.contains(&key) {
            return Err(Fault::message("cycle", "수식이나 롤업 참조가 순환합니다."));
        }
        if self.active.len() >= self.max_depth {
            return Err(Fault::message(
                "depth_limit",
                "계산 참조 깊이 한도를 넘었습니다.",
            ));
        }
        self.active.push(key.clone());
        let result = (|| {
            let value = match property.kind.as_str() {
                "formula" => {
                    let expression = property.config.get("expression");
                    if expression.null() || expression.string().is_some_and(|s| trim(s).is_empty())
                    {
                        V::Null
                    } else {
                        let expression = expression
                            .string()
                            .ok_or_else(|| {
                                Fault::message("parse_error", "수식을 읽지 못했습니다.")
                            })?
                            .clone();
                        let node = if let Some(node) = self.parsed.get(&expression) {
                            node.clone()
                        } else {
                            let node = Parser::new(&expression, self)?.parse()?;
                            self.retained_nodes += node.nodes.len();
                            if self.retained_nodes > 200000 {
                                return Err(Fault::message(
                                    "result_limit",
                                    "계산 문법 보관 한도를 넘었습니다.",
                                ));
                            }
                            self.parsed.insert(expression, node.clone());
                            node
                        };
                        self.eval(&node, db, row, 0)?
                    }
                }
                "rollup" => {
                    let relation_id = property
                        .config
                        .get("relationPropertyId")
                        .string()
                        .ok_or_else(|| {
                            Fault::message("missing_property", "롤업의 관계 속성을 선택해 주세요.")
                        })?;
                    let relation = self.property(db, relation_id)?;
                    if relation.kind != "relation" {
                        return Err(Fault::message(
                            "type_error",
                            "롤업에는 관계 속성이 필요합니다.",
                        ));
                    }
                    let relation_value = self.read(db, row, &text(&relation.id))?;
                    let refs = self.relations(&relation_value)?;
                    let target = property.config.get("targetPropertyId");
                    let calculation = if property.config.get("calculation").null() {
                        "count".to_owned()
                    } else {
                        property
                            .config
                            .get("calculation")
                            .string()
                            .map(|value| control_string(value))
                            .ok_or_else(|| {
                                Fault::message("type_error", "롤업 집계 방식이 올바르지 않습니다.")
                            })?
                    };
                    if target.null() && ["count", "countAll"].contains(&calculation.as_str()) {
                        V::Int(refs.len() as i64)
                    } else {
                        let target = target.string().ok_or_else(|| {
                            Fault::message("missing_property", "롤업의 대상 속성을 선택해 주세요.")
                        })?;
                        let mut values = Vec::new();
                        for (db, row) in refs {
                            values.push(self.read(db, row, target)?);
                        }
                        aggregate(&values, &calculation)?
                    }
                }
                _ => {
                    let value = self.databases[db].rows[row]
                        .values
                        .get(&property.id)
                        .clone();
                    if property.kind == "relation" {
                        self.relations(&value)?;
                    }
                    value
                }
            };
            bounded(&value)?;
            self.retain(&value)?;
            self.cache.insert(key, value.clone());
            Ok(value)
        })();
        let result = result.map_err(|mut fault: Fault| {
            if fault.path.is_empty() {
                fault.path = self.active.clone();
            }
            fault
        });
        self.active.pop();
        result
    }
    fn relations(&mut self, value: &V) -> QResult<Vec<(usize, usize)>> {
        if value.null() {
            return Ok(Vec::new());
        }
        let items = if let V::List(items) = value {
            items.as_ref()
        } else {
            std::slice::from_ref(value)
        };
        let mut result = Vec::new();
        for item in items {
            self.tick()?;
            let db = item.get("databaseId").string().ok_or_else(|| {
                Fault::message("type_error", "관계 값의 형식이 올바르지 않습니다.")
            })?;
            let row = item.get("rowId").string().ok_or_else(|| {
                Fault::message("type_error", "관계 값의 형식이 올바르지 않습니다.")
            })?;
            let db = self
                .databases
                .iter()
                .position(|v| text_eq(db, &v.id))
                .ok_or_else(|| {
                    Fault::message(
                        "missing_relation",
                        "관계 대상 데이터베이스를 불러오지 못했습니다.",
                    )
                })?;
            let row = self.row(db, row, true)?;
            result.push((db, row));
        }
        Ok(result)
    }
    fn retain(&mut self, value: &V) -> QResult<()> {
        self.retained_nodes += 1;
        match value {
            V::Str(value) => {
                if self
                    .retained
                    .insert((0, Arc::as_ptr(value) as *const u16 as usize))
                {
                    self.retained_units += value.len();
                }
            }
            V::List(value) => {
                if self
                    .retained
                    .insert((1, Arc::as_ptr(value) as *const V as usize))
                {
                    for value in value.iter() {
                        self.retain(value)?;
                    }
                }
            }
            V::Map(value)
                if self
                    .retained
                    .insert((2, Arc::as_ptr(value) as *const (Text, V) as usize)) =>
            {
                for (key, value) in value.iter() {
                    if self
                        .retained
                        .insert((0, Arc::as_ptr(key) as *const u16 as usize))
                    {
                        self.retained_units += key.len();
                    }
                    self.retain(value)?;
                }
            }
            _ => (),
        }
        if self.retained_units > 4000000 || self.retained_nodes > 200000 {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 보관 한도를 넘었습니다.",
            ));
        }
        Ok(())
    }

    fn eval(&mut self, ast: &Ast, db: usize, row: usize, depth: usize) -> QResult<V> {
        self.eval_node(ast, ast.root, db, row, depth)
    }
    fn eval_node(
        &mut self,
        ast: &Ast,
        index: usize,
        db: usize,
        row: usize,
        depth: usize,
    ) -> QResult<V> {
        self.tick()?;
        if depth > self.max_depth {
            return Err(Fault::message(
                "depth_limit",
                "수식 깊이 한도를 넘었습니다.",
            ));
        }
        let node = &ast.nodes[index];
        if node.kind == "literal" {
            return Ok(node.value.clone());
        }
        if node.kind == "list" {
            let mut result = Vec::new();
            for child in &node.children {
                result.push(self.eval_node(ast, *child, db, row, depth + 1)?);
            }
            return Ok(V::list(result));
        }
        if node.kind == "unary" {
            let value = self.eval_node(ast, node.children[0], db, row, depth + 1)?;
            return match node.value.utf8().as_deref() {
                Some("!") => Ok(V::Bool(!value.boolean_value()?)),
                Some("-") => Ok(value.number()?.negate()?.value()),
                Some("+") => Ok(value.number()?.value()),
                _ => Err(Fault::new("parse_error")),
            };
        }
        if node.kind == "binary" {
            let op = node.value.utf8().expect("operator");
            let a = self.eval_node(ast, node.children[0], db, row, depth + 1)?;
            if op == "&&" {
                return Ok(V::Bool(
                    a.boolean_value()?
                        && self
                            .eval_node(ast, node.children[1], db, row, depth + 1)?
                            .boolean_value()?,
                ));
            }
            if op == "||" {
                return Ok(V::Bool(
                    a.boolean_value()?
                        || self
                            .eval_node(ast, node.children[1], db, row, depth + 1)?
                            .boolean_value()?,
                ));
            }
            let b = self.eval_node(ast, node.children[1], db, row, depth + 1)?;
            return match op.as_str() {
                "+" | "-" | "*" => Ok(a.number()?.arithmetic(b.number()?, &op)?.value()),
                "/" => {
                    let denominator = b.number()?;
                    if denominator.f64() == 0.0 {
                        return Err(Fault::message(
                            "division_by_zero",
                            "0으로 나눌 수 없습니다.",
                        ));
                    }
                    Ok(Num::finite(a.number()?.f64() / denominator.f64())?.value())
                }
                "%" => {
                    let denominator = b.number()?;
                    if denominator.f64() == 0.0 {
                        return Err(Fault::message(
                            "division_by_zero",
                            "0으로 나눌 수 없습니다.",
                        ));
                    }
                    let numerator = a.number()?;
                    match (numerator, denominator) {
                        (Num::Int(a), Num::Int(b)) => {
                            let m = b as i128;
                            Ok(V::Int((a as i128).rem_euclid(m.abs()) as i64))
                        }
                        (a, b) => {
                            let modulus = b.f64().abs();
                            let mut remainder = a.f64() % modulus;
                            if remainder < 0.0 {
                                remainder += modulus;
                            }
                            if remainder == 0.0 {
                                remainder = 0.0;
                            }
                            Ok(Num::finite(remainder)?.value())
                        }
                    }
                }
                "==" => Ok(V::Bool(equal(&a, &b))),
                "!=" => Ok(V::Bool(!equal(&a, &b))),
                "<" => Ok(V::Bool(compare(&a, &b)? == Ordering::Less)),
                "<=" => Ok(V::Bool(compare(&a, &b)? != Ordering::Greater)),
                ">" => Ok(V::Bool(compare(&a, &b)? == Ordering::Greater)),
                ">=" => Ok(V::Bool(compare(&a, &b)? != Ordering::Less)),
                _ => Err(Fault::new("parse_error")),
            };
        }
        let name = node.value.utf8().expect("ASCII function").to_lowercase();
        let count = node.children.len();
        let at = |session: &mut Self, i: usize| {
            session.eval_node(ast, node.children[i], db, row, depth + 1)
        };
        let arity = |min: usize, max: usize| {
            if count < min || count > max {
                Err(Fault::message(
                    "argument_error",
                    "수식 함수의 인자 수가 올바르지 않습니다.",
                ))
            } else {
                Ok(())
            }
        };
        if name == "if" {
            arity(3, 3)?;
            return if at(self, 0)?.boolean_value()? {
                at(self, 1)
            } else {
                at(self, 2)
            };
        }
        if name == "and" || name == "or" {
            for i in 0..count {
                let value = at(self, i)?.boolean_value()?;
                if name == "and" && !value {
                    return Ok(V::Bool(false));
                }
                if name == "or" && value {
                    return Ok(V::Bool(true));
                }
            }
            return Ok(V::Bool(name == "and"));
        }
        if name == "prop" {
            arity(1, 1)?;
            let id = at(self, 0)?;
            let id = id.string().ok_or_else(|| Fault::new("type_error"))?;
            return self.read(db, row, id);
        }
        if name == "now" || name == "today" {
            arity(0, 0)?;
            let clock = self.clock.ok_or_else(|| {
                Fault::message(
                    "clock_required",
                    "현재 시각을 사용하는 수식에는 캡처한 시각이 필요합니다.",
                )
            })?;
            return Ok(V::s(if name == "now" {
                clock.iso()
            } else {
                clock.day()
            }));
        }
        let mut args = Vec::new();
        for i in 0..count {
            args.push(at(self, i)?);
        }
        match name.as_str() {
            "concat" => join(&args, &text("")),
            "empty" => {
                arity(1, 1)?;
                Ok(V::Bool(empty(&args[0])))
            }
            "length" => {
                arity(1, 1)?;
                let length = match &args[0] {
                    V::Str(v) => scalar_len(v),
                    V::List(v) => v.len(),
                    V::Map(v) => v.len(),
                    _ => return Err(Fault::new("type_error")),
                };
                Ok(V::Int(length as i64))
            }
            "sum" | "average" | "min" | "max" | "count" => {
                let mut values = Vec::new();
                for value in &args {
                    if let V::List(items) = value {
                        values.extend(items.iter().cloned());
                    } else {
                        values.push(value.clone());
                    }
                }
                aggregate(&values, &name)
            }
            "not" => {
                arity(1, 1)?;
                Ok(V::Bool(!args[0].boolean_value()?))
            }
            "abs" => {
                arity(1, 1)?;
                let number = args[0].number()?;
                Ok(if number.f64() < 0.0 {
                    number.negate()?
                } else {
                    number
                }
                .value())
            }
            "floor" => {
                arity(1, 1)?;
                Ok(V::Float(args[0].number()?.f64().floor()))
            }
            "ceil" => {
                arity(1, 1)?;
                Ok(V::Float(args[0].number()?.f64().ceil()))
            }
            "round" => {
                arity(1, 2)?;
                let places = if count == 2 {
                    args[1].number()?.f64()
                } else {
                    0.0
                };
                if !(-12.0..=12.0).contains(&places) || places.fract() != 0.0 {
                    return Err(Fault::new("argument_error"));
                }
                let scale = 10f64.powi(places as i32);
                let product = Num::finite(args[0].number()?.f64() * scale)?.f64();
                Ok(Num::finite(product.round() / scale)?.value())
            }
            "lower" | "upper" => {
                arity(1, 1)?;
                Ok(V::Str(case_map(&args[0].text_value()?, name == "upper")))
            }
            "trim" => {
                arity(1, 1)?;
                Ok(V::Str(trim(&args[0].text_value()?)))
            }
            "contains" => {
                arity(2, 2)?;
                let found = if let V::List(items) = &args[0] {
                    items.iter().any(|v| equal(v, &args[1]))
                } else {
                    find(&args[0].text_value()?, &args[1].text_value()?, 0).is_some()
                };
                Ok(V::Bool(found))
            }
            "replace" => {
                arity(3, 3)?;
                let source = args[0].text_value()?;
                let pattern = args[1].text_value()?;
                let replacement = args[2].text_value()?;
                let count = self.match_count(&source, &pattern)?;
                let length = source.len() as i128
                    + count as i128 * (replacement.len() as i128 - pattern.len() as i128);
                if length > 1000000 {
                    return Err(Fault::message(
                        "result_limit",
                        "수식 결과 크기 한도를 넘었습니다.",
                    ));
                }
                let mut result = Vec::with_capacity(length as usize);
                if pattern.is_empty() {
                    result.extend(replacement.iter().copied());
                    for c in source.iter() {
                        result.push(*c);
                        result.extend(replacement.iter().copied());
                    }
                } else {
                    let mut start = 0;
                    while let Some(found) = find(&source, &pattern, start) {
                        result.extend_from_slice(&source[start..found]);
                        result.extend(replacement.iter().copied());
                        start = found + pattern.len();
                    }
                    result.extend_from_slice(&source[start..]);
                }
                Ok(V::text(result))
            }
            "split" => {
                arity(2, 2)?;
                let source = args[0].text_value()?;
                let pattern = args[1].text_value()?;
                if self.match_count(&source, &pattern)? > 10000 {
                    return Err(Fault::message(
                        "result_limit",
                        "수식 목록 길이 한도를 넘었습니다.",
                    ));
                }
                if pattern.is_empty() {
                    return Ok(V::list(source.iter().map(|c| V::text(vec![*c]))));
                }
                let mut result = Vec::new();
                let mut start = 0;
                while let Some(found) = find(&source, &pattern, start) {
                    result.push(V::text(source[start..found].to_vec()));
                    start = found + pattern.len();
                }
                result.push(V::text(source[start..].to_vec()));
                Ok(V::list(result))
            }
            "join" => {
                arity(2, 2)?;
                let items = args[0].array().ok_or_else(|| Fault::new("type_error"))?;
                join(items, &args[1].text_value()?)
            }
            "date" | "datestart" => {
                arity(1, 1)?;
                Ok(V::s(dates::date(&args[0])?.iso()))
            }
            "dateend" => {
                arity(1, 1)?;
                let date = dates::range(&args[0])?;
                Ok(V::s(date.end.unwrap_or(date.start).iso()))
            }
            "dateadd" => {
                arity(3, 3)?;
                Ok(V::s(
                    dates::date(&args[0])?
                        .add(
                            args[1].number()?,
                            &control_string(&case_map(&args[2].text_value()?, false)),
                        )?
                        .iso(),
                ))
            }
            "datebetween" => {
                arity(3, 3)?;
                Ok(V::Int(dates::date(&args[0])?.between(
                    dates::date(&args[1])?,
                    &control_string(&case_map(&args[2].text_value()?, false)),
                )?))
            }
            "year" | "month" | "day" | "weekday" => {
                arity(1, 1)?;
                let date = dates::date(&args[0])?;
                let (y, m, d, _, _, _, _) = date.parts();
                Ok(V::Int(match name.as_str() {
                    "year" => y,
                    "month" => m,
                    "day" => d,
                    _ => date.weekday(),
                }))
            }
            "formatdate" => {
                arity(2, 2)?;
                dates::date(&args[0])?.format(&args[1].text_value()?)
            }
            _ => Err(Fault::message(
                "unsupported_function",
                "이 수식 함수는 지원하지 않습니다.",
            )),
        }
    }
    fn match_count(&mut self, source: &[u16], pattern: &[u16]) -> QResult<usize> {
        for _ in (0..source.len()).step_by(64) {
            self.tick()?;
        }
        if pattern.is_empty() {
            return Ok(source.len() + 1);
        }
        let (mut count, mut position) = (0, 0);
        while let Some(found) = find(source, pattern, position) {
            count += 1;
            self.tick()?;
            position = found + pattern.len();
        }
        Ok(count)
    }

    fn matches(&mut self, row: usize, filter: &V, depth: usize) -> QResult<bool> {
        self.tick()?;
        if depth > self.max_depth {
            return Err(Fault::new("depth_limit"));
        }
        for key in ["and", "or"] {
            if filter.has(key) {
                let fields = filter.map().ok_or_else(|| Fault::new("invalid_filter"))?;
                let items = filter
                    .get(key)
                    .array()
                    .ok_or_else(|| Fault::new("invalid_filter"))?;
                if fields.len() != 1 {
                    return Err(Fault::new("invalid_filter"));
                }
                if key == "and" {
                    for item in items {
                        if !matches!(item, V::Map(_)) {
                            return Err(Fault::message(
                                "invalid_filter",
                                "필터 조건을 읽지 못했습니다.",
                            ));
                        }
                        if !self.matches(row, item, depth + 1)? {
                            return Ok(false);
                        }
                    }
                    return Ok(true);
                }
                for item in items {
                    if !matches!(item, V::Map(_)) {
                        return Err(Fault::new("invalid_filter"));
                    }
                    if self.matches(row, item, depth + 1)? {
                        return Ok(true);
                    }
                }
                return Ok(false);
            }
        }
        let property = if filter.get("propertyId").null() {
            filter.get("property")
        } else {
            filter.get("propertyId")
        };
        let property = property
            .string()
            .ok_or_else(|| Fault::new("invalid_filter"))?;
        let op = if filter.get("operator").null() {
            filter.get("op")
        } else {
            filter.get("operator")
        };
        let op = op
            .string()
            .map(|value| control_string(value))
            .ok_or_else(|| Fault::new("invalid_filter"))?;
        let a = self.read(0, row, property)?;
        let b = filter.get("value");
        match op.as_str() {
            "isEmpty" => return Ok(empty(&a)),
            "isNotEmpty" => return Ok(!empty(&a)),
            "contains" | "notContains" => {
                let found = match (&a, b) {
                    (V::List(items), b) => items.iter().any(|v| equal(v, b)),
                    (V::Str(a), V::Str(b)) => {
                        find(&case_map(a, false), &case_map(b, false), 0).is_some()
                    }
                    _ => false,
                };
                return Ok(if op == "contains" { found } else { !found });
            }
            "startsWith" | "endsWith" => {
                if a.null() {
                    return Ok(false);
                }
                let a = case_map(&a.text_value()?, false);
                let b = case_map(&b.text_value()?, false);
                return Ok(if op == "startsWith" {
                    a.starts_with(&b)
                } else {
                    a.ends_with(&b)
                });
            }
            "in" | "notIn" => {
                let items = b.array().ok_or_else(|| Fault::new("invalid_filter"))?;
                let found = items.iter().any(|v| equal(v, &a));
                return Ok(if op == "in" { found } else { !found });
            }
            _ => (),
        }
        let date = self.property(0, property)?.kind == "date";
        if op == "equals" || op == "notEquals" {
            let same = if date && !a.null() && !b.null() {
                dates::date(&a)? == dates::date(b)?
            } else {
                equal(&a, b)
            };
            return Ok(if op == "equals" { same } else { !same });
        }
        if a.null() || b.null() {
            return Ok(false);
        }
        let comparison = if date {
            dates::date(&a)?.cmp(&dates::date(b)?)
        } else {
            compare(&a, b)?
        };
        match op.as_str() {
            "gt" | "after" => Ok(comparison == Ordering::Greater),
            "gte" | "onOrAfter" => Ok(comparison != Ordering::Less),
            "lt" | "before" => Ok(comparison == Ordering::Less),
            "lte" | "onOrBefore" => Ok(comparison != Ordering::Greater),
            _ => Err(Fault::message(
                "invalid_filter",
                "지원하지 않는 필터 조건입니다.",
            )),
        }
    }
    fn sort_value(&mut self, row: usize, sort: &V) -> QResult<Option<SortValue>> {
        self.tick()?;
        let id = if sort.get("propertyId").null() {
            sort.get("property")
        } else {
            sort.get("propertyId")
        };
        let id = id
            .string()
            .ok_or_else(|| Fault::message("invalid_sort", "정렬 속성이 올바르지 않습니다."))?;
        let direction = if sort.get("direction").null() {
            "ascending".to_owned()
        } else {
            sort.get("direction")
                .string()
                .map(|value| control_string(value))
                .ok_or_else(|| Fault::new("invalid_sort"))?
        };
        if !["ascending", "descending", "asc", "desc"].contains(&direction.as_str()) {
            return Err(Fault::new("invalid_sort"));
        }
        let row = text(&self.databases[0].rows[row].id);
        let result = self.value(0, &row, id);
        let value = result.get("value");
        if result.has("error") || value.null() {
            return Ok(None);
        }
        if self.property(0, id)?.kind == "date" {
            Ok(Some(SortValue::Date(dates::date(value)?)))
        } else {
            Ok(Some(match value {
                V::Int(_) | V::Float(_) => SortValue::Number(value.number()?),
                V::Bool(value) => SortValue::Bool(*value),
                V::Str(_) => SortValue::Text(self.normalized(value, 0)?),
                _ => SortValue::Json(self.normalized(value, 1)?),
            }))
        }
    }
    fn project(&mut self, view: &V) -> QResult<Projection> {
        let mut rows = Vec::new();
        for row in 0..self.databases[0].rows.len() {
            if self.databases[0].rows[row].archived {
                continue;
            }
            let include = if view.get("filter").null() {
                Ok(true)
            } else {
                self.matches(row, view.get("filter"), 0)
            };
            match include {
                Ok(true) => rows.push(row),
                Ok(false) => (),
                Err(fault) => self.record(fault),
            }
        }
        let sorts = view.get("sorts").array().unwrap_or_default();
        let sorted = (|| {
            let mut keys = Vec::new();
            for row in &rows {
                let mut values = Vec::new();
                for sort in sorts {
                    values.push(self.sort_value(*row, sort)?);
                }
                keys.push(values);
            }
            let mut indexes = (0..rows.len()).collect::<Vec<_>>();
            indexes.sort_by(|a, b| {
                for (i, sort) in sorts.iter().enumerate() {
                    let (a, b) = (&keys[*a][i], &keys[*b][i]);
                    let comparison = match (a, b) {
                        (None, None) => continue,
                        (None, Some(_)) => return Ordering::Greater,
                        (Some(_), None) => return Ordering::Less,
                        (Some(a), Some(b)) => sort_compare(a, b),
                    };
                    if comparison != Ordering::Equal {
                        return if sort
                            .get("direction")
                            .utf8()
                            .is_some_and(|s| s == "desc" || s == "descending")
                        {
                            comparison.reverse()
                        } else {
                            comparison
                        };
                    }
                }
                a.cmp(b)
            });
            Ok::<_, Fault>(indexes.into_iter().map(|i| rows[i]).collect::<Vec<_>>())
        })();
        match sorted {
            Ok(sorted) => rows = sorted,
            Err(fault) => self.record(fault),
        }
        let mut groups = Vec::<(Text, Vec<usize>)>::new();
        let mut group_indexes = BTreeMap::<Text, usize>::new();
        if let Some(group) = view.get("groupBy").string() {
            for row in &rows {
                let id = text(&self.databases[0].rows[*row].id);
                let result = self.value(0, &id, group);
                if result.has("error") {
                    continue;
                }
                let date = self.property(0, group)?.kind == "date";
                let value = result.get("value");
                let items = if let V::List(items) = value {
                    items.as_ref()
                } else {
                    std::slice::from_ref(value)
                };
                let fallback = [V::Null];
                let items = if items.is_empty() {
                    fallback.as_slice()
                } else {
                    items
                };
                let mut seen = BTreeSet::new();
                for item in items {
                    let kind = if date && !item.null() {
                        2
                    } else if matches!(item, V::Str(_) | V::Null)
                        || item.get("databaseId").string().is_some()
                            && item.get("rowId").string().is_some()
                    {
                        3
                    } else {
                        1
                    };
                    let key = self.normalized(item, kind)?;
                    if !seen.insert(key.clone()) {
                        continue;
                    }
                    self.group_membership()?;
                    if let Some(index) = group_indexes.get(&key) {
                        groups[*index].1.push(*row);
                    } else {
                        group_indexes.insert(key.clone(), groups.len());
                        groups.push((key, vec![*row]));
                    }
                }
            }
        }
        Ok(Projection {
            rows,
            groups,
            error_count: self.errors.len(),
        })
    }
    fn aggregate_rows(
        &mut self,
        property: &Text,
        calculation: &str,
        rows: Option<&[Text]>,
        view: Option<&V>,
    ) -> QResult<V> {
        let selected = if let Some(rows) = rows {
            rows.to_vec()
        } else if let Some(view) = view {
            self.project(view)?
                .rows
                .iter()
                .map(|row| text(&self.databases[0].rows[*row].id))
                .collect()
        } else {
            self.databases[0]
                .rows
                .iter()
                .filter(|r| !r.archived)
                .map(|r| text(&r.id))
                .collect()
        };
        let mut values = Vec::new();
        for row in selected {
            let row = self.row(0, &row, false)?;
            values.push(self.read(0, row, property)?);
        }
        aggregate(&values, calculation)
    }
    fn calendar(&mut self, property: &Text, view: Option<&V>, output: &OutputGuard) -> QResult<V> {
        let rows = if let Some(view) = view {
            self.project(view)?.rows
        } else {
            self.databases[0]
                .rows
                .iter()
                .enumerate()
                .filter(|(_, r)| !r.archived)
                .map(|(i, _)| i)
                .collect()
        };
        let mut result = Vec::new();
        let mut meter = output.meter.clone();
        let mut items = Entries::default();
        for row in rows {
            let value: QResult<_> = (|| {
                let value = self.read(0, row, property)?;
                if value.null() {
                    return Ok(None);
                }
                let range = dates::range(&value)?;
                let start = range.start.iso();
                let end = range.end.map(|value| value.iso());
                let mut fields = Entries::default();
                let row_id = meter
                    .utf8_text(&self.databases[0].rows[row].id)
                    .map_err(output_fault)?;
                meter
                    .field(&mut fields, "rowId", row_id)
                    .map_err(output_fault)?;
                let start_node = meter.utf8_text(&start).map_err(output_fault)?;
                meter
                    .field(&mut fields, "start", start_node)
                    .map_err(output_fault)?;
                let end_node = match &end {
                    Some(end) => meter.utf8_text(end),
                    None => meter.value(&V::Null),
                }
                .map_err(output_fault)?;
                meter
                    .field(&mut fields, "end", end_node)
                    .map_err(output_fault)?;
                let all_day = meter.value(&V::Bool(range.all_day)).map_err(output_fault)?;
                meter
                    .field(&mut fields, "allDay", all_day)
                    .map_err(output_fault)?;
                items.item(meter.object(fields).map_err(output_fault)?);
                output
                    .check_array(&meter, items, &self.errors, self.remaining)
                    .map_err(output_fault)?;
                let result = V::object([
                    ("rowId", V::s(&self.databases[0].rows[row].id)),
                    ("start", V::s(start)),
                    ("end", end.map_or(V::Null, V::s)),
                    ("allDay", V::Bool(range.all_day)),
                ]);
                Ok(Some((range.start, result)))
            })();
            match value {
                Ok(Some(value)) => result.push(value),
                Ok(None) => (),
                Err(fault) if fault.code == "query_too_large" => return Err(fault),
                Err(fault) => self.record(fault),
            }
        }
        result.sort_by_key(|v| v.0);
        Ok(V::list(result.into_iter().map(|(_, v)| v)))
    }
    fn chart(
        &mut self,
        group: &Text,
        property: Option<&Text>,
        calculation: &str,
        view: Option<&V>,
        output: &OutputGuard,
    ) -> QResult<V> {
        let view = view
            .cloned()
            .unwrap_or_else(|| V::Map(Vec::new().into()))
            .with("groupBy", V::Str(group.clone()));
        let selected = self.project(&view)?;
        let mut points = Vec::new();
        let mut meter = output.meter.clone();
        let mut items = Entries::default();
        for (key, rows) in selected.groups {
            let row_ids = rows
                .iter()
                .map(|row| text(&self.databases[0].rows[*row].id))
                .collect::<Vec<_>>();
            let result = if property.is_none() && calculation == "count" {
                Ok(V::Int(rows.len() as i64))
            } else {
                self.aggregate_rows(
                    property.unwrap_or(&text("")),
                    calculation,
                    Some(&row_ids),
                    None,
                )
            };
            let value = match result {
                Ok(value) => value,
                Err(fault) => {
                    self.record(fault);
                    continue;
                }
            };
            if !value.null() && !matches!(value, V::Int(_) | V::Float(_)) {
                return Err(Fault::message(
                    "type_error",
                    "차트에는 숫자 집계가 필요합니다.",
                ));
            }
            let label = label(&self.property(0, group)?, &key);
            let mut fields = Entries::default();
            let key_node = meter.text(&key).map_err(output_fault)?;
            meter
                .field(&mut fields, "key", key_node)
                .map_err(output_fault)?;
            let label_node = meter.text(&label).map_err(output_fault)?;
            meter
                .field(&mut fields, "label", label_node)
                .map_err(output_fault)?;
            let value_node = meter
                .value(if value.null() { &V::Int(0) } else { &value })
                .map_err(output_fault)?;
            meter
                .field(&mut fields, "value", value_node)
                .map_err(output_fault)?;
            let mut rows = Entries::default();
            for row in &row_ids {
                rows.item(meter.text(row).map_err(output_fault)?);
            }
            let rows = meter.array(rows).map_err(output_fault)?;
            meter
                .field(&mut fields, "rowIds", rows)
                .map_err(output_fault)?;
            items.item(meter.object(fields).map_err(output_fault)?);
            output
                .check_array(&meter, items, &self.errors, self.remaining)
                .map_err(output_fault)?;
            points.push(V::object([
                ("key", V::Str(key)),
                ("label", V::Str(label)),
                ("value", if value.null() { V::Int(0) } else { value }),
                ("rowIds", V::list(row_ids.into_iter().map(V::Str))),
            ]));
        }
        Ok(V::list(points))
    }
}

enum SortValue {
    Number(Num),
    Bool(bool),
    Text(Text),
    Date(Date),
    Json(Text),
}
fn sort_compare(a: &SortValue, b: &SortValue) -> Ordering {
    let rank = |v: &SortValue| match v {
        SortValue::Number(_) => 0,
        SortValue::Bool(_) => 1,
        SortValue::Text(_) => 2,
        SortValue::Date(_) => 3,
        SortValue::Json(_) => 4,
    };
    let order = rank(a).cmp(&rank(b));
    if order != Ordering::Equal {
        return order;
    }
    match (a, b) {
        (SortValue::Number(a), SortValue::Number(b)) => a.compare(*b),
        (SortValue::Bool(a), SortValue::Bool(b)) => a.cmp(b),
        (SortValue::Date(a), SortValue::Date(b)) => a.cmp(b),
        (SortValue::Text(a), SortValue::Text(b)) | (SortValue::Json(a), SortValue::Json(b)) => {
            a.cmp(b)
        }
        _ => Ordering::Equal,
    }
}
fn group_key(value: &V) -> QResult<Text> {
    if value.null() {
        return Ok(text(""));
    }
    if let V::Str(value) = value {
        return Ok(value.clone());
    }
    if value.get("databaseId").string().is_some() && value.get("rowId").string().is_some() {
        let mut key = value.get("databaseId").text_value()?.to_vec();
        key.push(b'/' as u16);
        key.extend(value.get("rowId").text_value()?.iter().copied());
        return Ok(key.into());
    }
    json_text(value)
}
fn label(property: &Property, key: &Text) -> Text {
    if key.is_empty() {
        return text("비어 있음");
    }
    if let Some(options) = property.config.get("options").array() {
        for option in options {
            if option.get("id").string() == Some(key)
                && let Some(name) = option.get("name").string()
            {
                return name.clone();
            }
        }
    }
    key.clone()
}

fn join(values: &[V], separator: &[u16]) -> QResult<V> {
    let mut strings = Vec::new();
    let mut length = 0usize;
    for value in values {
        bounded(value)?;
        let value = stringify(value)?;
        length = length
            .checked_add(
                value.len()
                    + if strings.is_empty() {
                        0
                    } else {
                        separator.len()
                    },
            )
            .ok_or_else(|| Fault::new("result_limit"))?;
        if length > 1000000 {
            return Err(Fault::message(
                "result_limit",
                "계산 결과 크기 한도를 넘었습니다.",
            ));
        }
        strings.push(value);
    }
    let mut result = Vec::with_capacity(length);
    for (i, value) in strings.iter().enumerate() {
        if i > 0 {
            result.extend_from_slice(separator);
        }
        result.extend(value.iter().copied());
    }
    Ok(V::text(result))
}
fn aggregate(values: &[V], calculation: &str) -> QResult<V> {
    if ![
        "showOriginal",
        "showUnique",
        "countAll",
        "count",
        "countEmpty",
        "sum",
        "average",
        "min",
        "max",
    ]
    .contains(&calculation)
    {
        return Err(Fault::message(
            "unsupported_aggregate",
            "지원하지 않는 집계입니다.",
        ));
    }
    bounded(&V::list(values.iter().cloned()))?;
    if calculation == "showOriginal" {
        return Ok(V::list(values.iter().cloned()));
    }
    if calculation == "showUnique" {
        let mut result = Vec::new();
        let mut seen = BTreeSet::new();
        for value in values {
            if seen.insert(unique_key(value)) {
                result.push(value.clone());
            }
        }
        return Ok(V::list(result));
    }
    if calculation == "countAll" {
        return Ok(V::Int(values.len() as i64));
    }
    let total_count = values.len();
    let values = values.iter().filter(|v| !empty(v)).collect::<Vec<_>>();
    if calculation == "count" {
        return Ok(V::Int(values.len() as i64));
    }
    if calculation == "countEmpty" {
        return Ok(V::Int((total_count - values.len()) as i64));
    }
    let numbers = values
        .iter()
        .map(|v| v.number())
        .collect::<QResult<Vec<_>>>()?;
    if calculation == "sum" || calculation == "average" {
        let mut total = Num::Int(0);
        for value in &numbers {
            total = total.arithmetic(*value, "+")?;
        }
        return if calculation == "sum" {
            Ok(total.value())
        } else if numbers.is_empty() {
            Ok(V::Null)
        } else {
            Ok(Num::finite(total.f64() / numbers.len() as f64)?.value())
        };
    }
    let Some(mut result) = numbers.first().copied() else {
        return Ok(V::Null);
    };
    for value in numbers.iter().skip(1) {
        let cmp = value.compare(result);
        if calculation == "min" && cmp == Ordering::Less
            || calculation == "max" && cmp == Ordering::Greater
        {
            result = *value;
        }
    }
    Ok(result.value())
}

struct Node {
    kind: &'static str,
    value: V,
    children: Vec<usize>,
}
struct Ast {
    nodes: Vec<Node>,
    root: usize,
}
struct Token {
    kind: String,
    value: V,
}
struct Parser<'a> {
    tokens: Vec<Token>,
    position: usize,
    depth: usize,
    nodes: Vec<Node>,
    session: &'a mut Session,
}
impl<'a> Parser<'a> {
    fn new(source: &Text, session: &'a mut Session) -> QResult<Self> {
        if source.len() > 8192 {
            return Err(Fault::message(
                "budget_exceeded",
                "수식 길이 한도를 넘었습니다.",
            ));
        }
        let mut parser = Self {
            tokens: Vec::new(),
            position: 0,
            depth: 0,
            nodes: Vec::new(),
            session,
        };
        parser.scan(source)?;
        Ok(parser)
    }
    fn scan(&mut self, source: &[u16]) -> QResult<()> {
        let mut i = 0;
        while i < source.len() {
            self.session.tick()?;
            let c = source[i];
            if regex_space(c) {
                i += 1;
                continue;
            }
            if c == b'"' as u16 || c == b'\'' as u16 {
                let quote = c;
                let mut buffer = Vec::new();
                i += 1;
                let mut closed = false;
                while i < source.len() {
                    let mut c = source[i];
                    i += 1;
                    if c == quote {
                        closed = true;
                        break;
                    }
                    if c == b'\\' as u16 {
                        if i >= source.len() {
                            return Err(Fault::new("parse_error"));
                        }
                        c = source[i];
                        i += 1;
                        match c {
                            110 => buffer.push(10),
                            114 => buffer.push(13),
                            116 => buffer.push(9),
                            98 => buffer.push(8),
                            102 => buffer.push(12),
                            117 => {
                                if i + 4 > source.len() {
                                    return Err(Fault::new("parse_error"));
                                }
                                let mut code = 0u16;
                                for c in &source[i..i + 4] {
                                    code = code * 16
                                        + hex(*c).ok_or_else(|| Fault::new("parse_error"))?;
                                }
                                buffer.push(code);
                                i += 4;
                            }
                            34 | 39 | 92 | 47 => buffer.push(c),
                            _ => return Err(Fault::new("parse_error")),
                        }
                    } else {
                        buffer.push(c);
                    }
                }
                if !closed {
                    return Err(Fault::message(
                        "parse_error",
                        "문자열 따옴표가 닫히지 않았습니다.",
                    ));
                }
                self.tokens.push(Token {
                    kind: "literal".to_owned(),
                    value: V::text(buffer),
                });
                continue;
            }
            if digit(c) || c == b'.' as u16 && source.get(i + 1).is_some_and(|c| digit(*c)) {
                let start = i;
                while i < source.len() && digit(source[i]) {
                    i += 1;
                }
                if source.get(i) == Some(&(b'.' as u16))
                    && source.get(i + 1).is_some_and(|c| digit(*c))
                {
                    i += 1;
                    while i < source.len() && digit(source[i]) {
                        i += 1;
                    }
                }
                if source
                    .get(i)
                    .is_some_and(|c| *c == b'e' as u16 || *c == b'E' as u16)
                {
                    let mut end = i + 1;
                    if source
                        .get(end)
                        .is_some_and(|c| *c == b'+' as u16 || *c == b'-' as u16)
                    {
                        end += 1;
                    }
                    let first = end;
                    while end < source.len() && digit(source[end]) {
                        end += 1;
                    }
                    if end > first {
                        i = end;
                    }
                }
                let literal = String::from_utf16(&source[start..i]).expect("ASCII number");
                let value = if !literal.contains(['.', 'e', 'E']) {
                    literal
                        .parse::<i64>()
                        .map(V::Int)
                        .unwrap_or_else(|_| V::Float(literal.parse().unwrap_or(f64::INFINITY)))
                } else {
                    V::Float(literal.parse().unwrap_or(f64::INFINITY))
                };
                if matches!(value,V::Float(v)if !v.is_finite()) {
                    return Err(Fault::new("numeric_overflow"));
                }
                self.tokens.push(Token {
                    kind: "literal".to_owned(),
                    value,
                });
                continue;
            }
            if alpha(c) || c == b'_' as u16 {
                let start = i;
                i += 1;
                while i < source.len()
                    && (alpha(source[i]) || digit(source[i]) || source[i] == b'_' as u16)
                {
                    i += 1;
                }
                let name = String::from_utf16(&source[start..i]).expect("ASCII name");
                let token = match name.as_str() {
                    "true" => Token {
                        kind: "literal".to_owned(),
                        value: V::Bool(true),
                    },
                    "false" => Token {
                        kind: "literal".to_owned(),
                        value: V::Bool(false),
                    },
                    "null" => Token {
                        kind: "literal".to_owned(),
                        value: V::Null,
                    },
                    _ => Token {
                        kind: "identifier".to_owned(),
                        value: V::s(name),
                    },
                };
                self.tokens.push(token);
                continue;
            }
            let pair = source
                .get(i..i + 2)
                .and_then(|v| String::from_utf16(v).ok())
                .unwrap_or_default();
            if ["&&", "||", "==", "!=", "<=", ">="].contains(&pair.as_str()) {
                self.tokens.push(Token {
                    kind: pair.clone(),
                    value: V::s(pair),
                });
                i += 2;
                continue;
            }
            if b"+-*/%<>()[],!".contains(&(u8::try_from(c).unwrap_or(0))) {
                let op = (c as u8 as char).to_string();
                self.tokens.push(Token {
                    kind: op.clone(),
                    value: V::s(op),
                });
                i += 1;
                continue;
            }
            return Err(Fault::message(
                "parse_error",
                "허용하지 않는 수식 문자가 있습니다.",
            ));
        }
        self.tokens.push(Token {
            kind: "eof".to_owned(),
            value: V::Null,
        });
        Ok(())
    }
    fn kind(&self) -> &str {
        &self.tokens[self.position].kind
    }
    fn take(&mut self, kind: &str) -> bool {
        if self.kind() == kind {
            self.position += 1;
            true
        } else {
            false
        }
    }
    fn require(&mut self, kind: &str) -> QResult<()> {
        if self.take(kind) {
            Ok(())
        } else {
            Err(Fault::message(
                "parse_error",
                "수식 괄호나 구분자가 올바르지 않습니다.",
            ))
        }
    }
    fn node(&mut self, kind: &'static str, value: V, children: Vec<usize>) -> usize {
        let i = self.nodes.len();
        self.nodes.push(Node {
            kind,
            value,
            children,
        });
        i
    }
    fn parse(mut self) -> QResult<Arc<Ast>> {
        let root = self.expression(0)?;
        if self.kind() != "eof" {
            return Err(Fault::new("parse_error"));
        }
        Ok(Arc::new(Ast {
            nodes: self.nodes,
            root,
        }))
    }
    fn expression(&mut self, min: i32) -> QResult<usize> {
        self.session.tick()?;
        self.depth += 1;
        if self.depth > self.session.max_depth {
            return Err(Fault::new("depth_limit"));
        }
        let result = (|| {
            let mut left;
            if ["!", "-", "+"].contains(&self.kind()) {
                let op = self.kind().to_owned();
                self.position += 1;
                let child = self.expression(7)?;
                left = self.node("unary", V::s(op), vec![child]);
            } else if self.kind() == "literal" {
                let value = self.tokens[self.position].value.clone();
                self.position += 1;
                left = self.node("literal", value, Vec::new());
            } else if self.take("(") {
                left = self.expression(0)?;
                self.require(")")?;
            } else if self.take("[") {
                let mut children = Vec::new();
                if !self.take("]") {
                    loop {
                        children.push(self.expression(0)?);
                        if !self.take(",") {
                            break;
                        }
                    }
                    self.require("]")?;
                }
                left = self.node("list", V::Null, children);
            } else if self.kind() == "identifier" {
                let name = self.tokens[self.position].value.clone();
                self.position += 1;
                self.require("(")?;
                let mut children = Vec::new();
                if !self.take(")") {
                    loop {
                        children.push(self.expression(0)?);
                        if !self.take(",") {
                            break;
                        }
                    }
                    self.require(")")?;
                }
                left = self.node("call", name, children);
            } else {
                return Err(Fault::message("parse_error", "수식 값을 읽지 못했습니다."));
            }
            while precedence(self.kind()) >= min {
                let op = self.kind().to_owned();
                let level = precedence(&op);
                self.position += 1;
                let right = self.expression(level + 1)?;
                left = self.node("binary", V::s(op), vec![left, right]);
            }
            Ok(left)
        })();
        self.depth -= 1;
        result
    }
}
fn precedence(op: &str) -> i32 {
    match op {
        "||" => 1,
        "&&" => 2,
        "==" | "!=" => 3,
        "<" | "<=" | ">" | ">=" => 4,
        "+" | "-" => 5,
        "*" | "/" | "%" => 6,
        _ => -1,
    }
}
fn digit(c: u16) -> bool {
    (b'0' as u16..=b'9' as u16).contains(&c)
}
fn alpha(c: u16) -> bool {
    (b'A' as u16..=b'Z' as u16).contains(&c) || (b'a' as u16..=b'z' as u16).contains(&c)
}
fn hex(c: u16) -> Option<u16> {
    match c {
        48..=57 => Some(c - 48),
        65..=70 => Some(c - 65 + 10),
        97..=102 => Some(c - 97 + 10),
        _ => None,
    }
}
fn regex_space(c: u16) -> bool {
    matches!(c,9..=13|32|0xa0|0x1680|0x2000..=0x200a|0x2028|0x2029|0x202f|0x205f|0x3000|0xfeff)
}

#[cfg(test)]
mod normalized_key_tests {
    use super::*;
    const PROPERTY: &str = "33333333-3333-4333-8333-333333333333";
    fn session(values: Vec<V>) -> Session {
        let database = Database {
            id: "11111111-1111-4111-8111-111111111111".to_owned(),
            properties: vec![Property {
                id: PROPERTY.to_owned(),
                name: text("Future"),
                kind: "future".to_owned(),
                config: V::object([]),
            }],
            rows: values
                .into_iter()
                .enumerate()
                .map(|(index, value)| Row {
                    id: format!("{index:08x}-2222-4222-8222-222222222222"),
                    values: V::object([(PROPERTY, value)]),
                    archived: false,
                })
                .collect(),
        };
        Session {
            databases: vec![database],
            clock: None,
            max_depth: 32,
            remaining: 1000000,
            cache: BTreeMap::new(),
            parsed: BTreeMap::new(),
            active: Vec::new(),
            errors: Vec::new(),
            retained: BTreeSet::new(),
            retained_units: 0,
            retained_nodes: 0,
            normalized: BTreeMap::new(),
            normalization_exhausted: false,
        }
    }
    #[test]
    fn shared_sort_source_prepares_and_retains_one_key() {
        let source = V::object([("escaped", V::text(vec![1; 100000]))]);
        let mut query = session(vec![]);
        query.retain(&source).unwrap();
        let key = query.normalized(&source, 1).unwrap();
        let units = query.retained_units;
        let nodes = query.retained_nodes;
        for _ in 0..1000 {
            assert!(Arc::ptr_eq(&key, &query.normalized(&source, 1).unwrap()));
        }
        assert_eq!(query.normalized.len(), 1);
        assert_eq!(query.retained_units, units);
        assert_eq!(query.retained_nodes, nodes);
    }
    #[test]
    fn escaped_sort_map_exceeding_key_budget_records_a_fault() {
        let source = V::object([("escaped", V::text(vec![1; 700000]))]);
        let mut query = session(vec![source.clone(), source]);
        let view = V::object([(
            "sorts",
            V::list([V::object([("propertyId", V::s(PROPERTY))])]),
        )]);
        let projection = query.project(&view).unwrap();
        assert_eq!(projection.rows, vec![0, 1]);
        assert_eq!(query.errors[0].code, "query_too_large");
        assert!(query.retained_units <= 4000000);
    }
    #[test]
    fn project_bounds_distinct_nested_keys_before_output_materialization() {
        let shared = V::text(vec![1; 100000]);
        let mut query = session(
            (0..12)
                .map(|index| V::list([V::list([shared.clone(), V::s(format!("row {index}"))])]))
                .collect(),
        );
        let result = query.project(&V::object([("groupBy", V::s(PROPERTY))]));
        assert_eq!(result.err().unwrap().code, "query_too_large");
        assert!(query.retained_units <= 4000000);
        assert!(query.normalized.len() < 12);
    }
    #[test]
    fn project_bounds_memberships_when_rows_share_a_large_array() {
        let shared = V::list((0..1000).map(V::Int));
        let mut query = session((0..1000).map(|_| shared.clone()).collect());
        let result = query.project(&V::object([("groupBy", V::s(PROPERTY))]));
        assert_eq!(result.err().unwrap().code, "query_too_large");
        assert!(query.retained_nodes <= 200000);
    }
}
