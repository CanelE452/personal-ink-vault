use super::{ApiResult, error, invalid, valid_id};
use chrono::{DateTime, Datelike, Days, NaiveDate, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;
use regex::Regex;
use serde_json::{Map, Number, Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::sync::OnceLock;

const WRITABLE: &[&str] = &[
    "title",
    "text",
    "number",
    "status",
    "select",
    "multiSelect",
    "date",
    "checkbox",
    "url",
    "email",
    "phone",
];
const MAX_RULES: usize = 64;
const MAX_ACTIONS: usize = 32;
const MAX_BATCH_ACTIONS: usize = 128;
const MAX_RECEIPTS: usize = 10_000;
const MAX_ROWS: usize = 10_000;
const MAX_DUE: usize = 32;
const MAX_SCAN: usize = 3660;

/// Reads only the supplied snapshot and captured UTC timestamp. The existing
/// revision writer must persist the returned database as one snapshot.
pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    bounded(&Value::Object(request.clone()))?;
    let database = request.get("database").ok_or_else(invalid)?;
    validate_database(database)?;
    let device = uuid(request.get("deviceId"))?;
    match request
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("apply")
    {
        "validate" => {
            for rule in rules(database)? {
                validate_rule(rule, database)?;
            }
            Ok(json!({"valid":true}))
        }
        "validateSnapshot" => Ok(json!({"valid":true})),
        "due" => due(request, database, device),
        "apply" => execute(request, database, device),
        _ => Err(error(
            "unsupported_mode",
            "Workspace action mode is not supported",
        )),
    }
}

fn execute(request: &Map<String, Value>, database: &Value, device: &str) -> ApiResult<Value> {
    let captured = timestamp(request.get("capturedAtUtcMs"))?;
    let revision = uuid(request.get("inputRevision"))?;
    let db_id = uuid(database.get("id"))?;
    let mut event = object(request.get("event").ok_or_else(invalid)?)?.clone();
    let kind = text(event.get("type"))?.to_owned();
    let scope = request
        .get("ruleId")
        .map(|value| uuid(Some(value)))
        .transpose()?;
    match kind.as_str() {
        "manual" if scope.is_none() => {
            return Err(error("missing_rule", "Manual events require a rule ID"));
        }
        "schedule" => {
            let rule_id =
                scope.ok_or_else(|| error("missing_rule", "Schedule events require a rule ID"))?;
            let slot = timestamp(event.get("scheduledForUtcMs"))?;
            event.insert(
                "id".into(),
                json!(derived_id("schedule", &[db_id, rule_id, &slot.to_string()])),
            );
            event.remove("rowId");
        }
        "rowAdded" => {
            let row_id = uuid(event.get("rowId"))?;
            event.insert(
                "id".into(),
                json!(derived_id("row-added", &[db_id, row_id])),
            );
        }
        "manual" | "propertyChanged" => {
            uuid(event.get("id"))?;
        }
        _ => return Err(error("unsupported_trigger", "Event type is not supported")),
    }
    let event_id = uuid(event.get("id"))?.to_owned();
    let origin = event
        .get("origin")
        .and_then(Value::as_str)
        .unwrap_or("user")
        .to_owned();
    if !matches!(origin.as_str(), "user" | "button" | "form" | "automation") {
        return Err(error("invalid_event", "Event origin is not supported"));
    }
    event.insert("origin".into(), json!(origin));
    let lineage = array(event.get("lineage"))?;
    if lineage.len() > 16 {
        return Err(error(
            "automation_cycle",
            "Automation lineage exceeds its limit",
        ));
    }
    let mut seen = BTreeSet::new();
    for id in lineage {
        if !seen.insert(uuid(Some(id))?) {
            return Err(error(
                "automation_cycle",
                "Automation lineage contains a cycle",
            ));
        }
    }
    let lineage_ids = seen.into_iter().map(str::to_owned).collect::<BTreeSet<_>>();
    event.entry("lineage").or_insert_with(|| json!([]));
    let event_value = Value::Object(event.clone());
    let event_digest = digest(&json!({"event":event_value,"ruleId":scope}));
    let previous = executions(database)?;
    let repeated = previous
        .iter()
        .filter(|receipt| receipt["eventId"] == event_id)
        .collect::<Vec<_>>();
    if !repeated.is_empty() {
        if repeated
            .iter()
            .any(|receipt| receipt["eventDigest"] != event_digest)
        {
            return Err(error(
                "event_conflict",
                "The event ID was already used for different content",
            ));
        }
        return Ok(
            json!({"database":database,"receipts":repeated,"duplicate":true,"changed":false}),
        );
    }
    if kind == "schedule" {
        let rule = rules(database)?
            .iter()
            .find(|rule| rule.get("id").and_then(Value::as_str) == scope)
            .ok_or_else(|| error("missing_rule", "The requested schedule rule was not found"))?;
        if let Some(row_id) = schedule_row(rule, database)? {
            event.insert("rowId".into(), json!(row_id));
        }
    }
    if origin == "automation" {
        return Err(error(
            "automation_cycle",
            "Automation-generated events cannot trigger another automation",
        ));
    }
    let event_row = event.get("rowId").map(|id| uuid(Some(id))).transpose()?;
    if matches!(kind.as_str(), "propertyChanged" | "rowAdded") {
        let row_id =
            event_row.ok_or_else(|| error("missing_row", "This event requires a row ID"))?;
        let row = find_row(database, row_id)?;
        if archived(row)? {
            return Err(error(
                "archived_row",
                "Archived rows cannot trigger actions",
            ));
        }
    }
    if kind == "propertyChanged" {
        let property_id = uuid(event.get("propertyId"))?;
        let property = find_property(database, property_id)?;
        let old = event.get("oldValue").ok_or_else(invalid)?;
        let new = event.get("value").ok_or_else(invalid)?;
        validate_value(property, old)?;
        validate_value(property, new)?;
        let row = find_row(database, event_row.unwrap_or_default())?;
        if cell(row, property_id) != new || old == new {
            return Err(error(
                "stale_event",
                "The property event does not match the supplied input snapshot",
            ));
        }
    }
    let mut selected = Vec::new();
    for rule in rules(database)? {
        let rule_id = uuid(rule.get("id"))?;
        if scope.is_some_and(|selected| selected != rule_id) {
            continue;
        }
        if !rule.get("enabled").and_then(Value::as_bool).unwrap_or(true) {
            if scope.is_some() {
                return Err(error("disabled_rule", "This automation rule is disabled"));
            }
            continue;
        }
        let trigger = object(rule.get("trigger").ok_or_else(invalid)?)?;
        let trigger_type = text(trigger.get("type"))?;
        if trigger_type != kind {
            if scope.is_some() {
                return Err(error(
                    "trigger_mismatch",
                    "The event does not match this rule trigger",
                ));
            }
            continue;
        }
        if kind == "propertyChanged" && trigger.get("propertyId") != event.get("propertyId") {
            continue;
        }
        validate_rule(rule, database)?;
        if lineage_ids.contains(rule_id) {
            return Err(error(
                "automation_cycle",
                "The rule already occurs in the event lineage",
            ));
        }
        if kind == "schedule" {
            let schedule = Schedule::parse(rule)?;
            if schedule.owner != device {
                return Err(error(
                    "not_execution_owner",
                    "This device does not own the repeating schedule",
                ));
            }
            let slot = timestamp(event.get("scheduledForUtcMs"))?;
            if slot > captured {
                return Err(error(
                    "not_due",
                    "The scheduled occurrence has not happened yet",
                ));
            }
            let local_date = from_millis(slot)?
                .with_timezone(&schedule.zone)
                .date_naive();
            if schedule.occurrence(local_date)? != Some(slot) {
                return Err(error(
                    "not_due",
                    "The UTC slot is not an occurrence of the local calendar schedule",
                ));
            }
        }
        let matches = match rule.get("condition").filter(|v| !v.is_null()) {
            Some(condition) => {
                let row_id = event_row
                    .ok_or_else(|| error("missing_row", "Rule conditions require an event row"))?;
                condition_matches(condition, find_row(database, row_id)?, database)?
            }
            None => true,
        };
        for action in array(rule.get("actions"))? {
            validate_action_target(action, database, event_row, kind == "schedule")?;
        }
        selected.push((rule, matches));
    }
    if scope.is_some() && selected.is_empty() {
        return Err(error(
            "missing_rule",
            "The requested automation rule was not found",
        ));
    }
    let total_actions = selected
        .iter()
        .map(|(rule, _)| array(rule.get("actions")).map_or(0, <[Value]>::len))
        .sum::<usize>();
    if selected.len() > 32 || total_actions > MAX_BATCH_ACTIONS {
        return Err(error(
            "action_limit",
            "An event exceeds the rule or action execution budget",
        ));
    }
    if previous.len() + selected.len() > MAX_RECEIPTS {
        return Err(error(
            "receipt_limit",
            "Automation receipt limit was reached",
        ));
    }
    let mut working = database.clone();
    let mut receipts = Vec::new();
    for (rule, matches) in selected {
        let rule_id = uuid(rule.get("id"))?;
        let mut results = Vec::new();
        if matches {
            for action in array(rule.get("actions"))? {
                let action_id = uuid(action.get("id"))?;
                let action_type = text(action.get("type"))?;
                let template_id = if action_type == "addRowFromTemplate" {
                    if request.get("materializeTemplates").and_then(Value::as_bool) != Some(true) {
                        return Err(error(
                            "template_materialization_required",
                            "The caller must materialize the template row before saving",
                        ));
                    }
                    Some(uuid(action.get("templateId"))?)
                } else {
                    None
                };
                let row_id = if action_type == "addRow" || template_id.is_some() {
                    let row_id = derived_id("action-row", &[db_id, rule_id, &event_id, action_id]);
                    if rows(&working)?.iter().any(|row| row["id"] == row_id) {
                        return Err(error(
                            "row_identity_conflict",
                            "The generated action row ID already exists",
                        ));
                    }
                    let items = working["rows"].as_array_mut().ok_or_else(invalid)?;
                    if items.len() >= MAX_ROWS {
                        return Err(error("row_limit", "Database row limit was reached"));
                    }
                    items.push(json!({"id":row_id,"values":action["values"],"body":{"version":1,"blocks":[]},"archived":false}));
                    row_id
                } else {
                    let row_id = target_row(action, event_row)?.to_owned();
                    let property_id = uuid(action.get("propertyId"))?;
                    let row = working["rows"]
                        .as_array_mut()
                        .ok_or_else(invalid)?
                        .iter_mut()
                        .find(|row| row["id"] == row_id)
                        .ok_or_else(|| error("missing_row", "Action row was not found"))?;
                    row.as_object_mut()
                        .ok_or_else(invalid)?
                        .entry("values")
                        .or_insert_with(|| json!({}))
                        .as_object_mut()
                        .ok_or_else(invalid)?
                        .insert(property_id.to_owned(), action["value"].clone());
                    row_id
                };
                let result_type = if template_id.is_some() {
                    "addRow"
                } else {
                    action_type
                };
                let mut result = json!({"actionId":action_id,"type":result_type,"rowId":row_id});
                if let Some(template_id) = template_id {
                    result["templateId"] = json!(template_id);
                }
                if let Some(property) = action.get("propertyId") {
                    result["propertyId"] = property.clone();
                }
                results.push(result);
            }
        }
        let mut receipt = json!({"id":derived_id("execution", &[db_id,rule_id,&event_id]),"ruleId":rule_id,"ruleVersion":rule["version"],
          "eventId":event_id,"eventDigest":event_digest,"ruleDigest":digest(rule),"inputRevision":revision,"deviceId":device,
          "capturedAtUtcMs":captured,"status":if matches {"completed"} else {"skipped"},"actionResults":results});
        if kind == "schedule" {
            let schedule = Schedule::parse(rule)?;
            receipt["scheduledForUtcMs"] = event["scheduledForUtcMs"].clone();
            receipt["timeZone"] = json!(schedule.zone_name);
            receipt["tzdbVersion"] = json!(chrono_tz::IANA_TZDB_VERSION);
            if let Some(row_id) = event_row {
                receipt["eventRowId"] = json!(row_id);
            }
        }
        receipts.push(receipt);
    }
    if !receipts.is_empty() {
        let mut ledger = previous.to_vec();
        ledger.extend(receipts.iter().cloned());
        working
            .as_object_mut()
            .ok_or_else(invalid)?
            .insert("automationExecutions".into(), Value::Array(ledger));
    }
    bounded(&working)?;
    Ok(
        json!({"database":working,"receipts":receipts,"duplicate":false,"changed":!receipts.is_empty()}),
    )
}

fn due(request: &Map<String, Value>, database: &Value, device: &str) -> ApiResult<Value> {
    let captured = timestamp(request.get("capturedAtUtcMs"))?;
    let since = request
        .get("sinceUtcMs")
        .filter(|value| !value.is_null())
        .map(|value| timestamp(Some(value)))
        .transpose()?;
    if since.is_some_and(|since| since > captured) {
        return Err(error(
            "invalid_time",
            "The due scan horizon cannot exceed its UTC cutoff",
        ));
    }
    let cutoff = from_millis(captured)?;
    let definitions = rules(database)?;
    let signature = digest(
        &json!({"rules":definitions,"deviceId":device,"capturedAtUtcMs":captured,"sinceUtcMs":since}),
    );
    let mut rule_index = 0_usize;
    let mut resume_date = None;
    if let Some(cursor) = request.get("cursor").filter(|v| !v.is_null()) {
        let cursor_since = cursor
            .get("sinceUtcMs")
            .filter(|value| !value.is_null())
            .map(|value| {
                value
                    .as_i64()
                    .ok_or_else(|| error("invalid_cursor", "The due cursor horizon is invalid"))
            })
            .transpose()?;
        if cursor_since != since {
            return Err(error(
                "invalid_cursor",
                "The due cursor belongs to a different UTC horizon",
            ));
        }
        if cursor.get("signature").and_then(Value::as_str) != Some(&signature) {
            return Err(error(
                "stale_cursor",
                "The due cursor belongs to another rule snapshot, device or time cutoff",
            ));
        }
        rule_index = cursor
            .get("ruleIndex")
            .and_then(Value::as_u64)
            .and_then(|v| usize::try_from(v).ok())
            .filter(|v| *v <= definitions.len())
            .ok_or_else(invalid)?;
        resume_date = Some(date(text(cursor.get("localDate"))?)?);
    }
    let completed = executions(database)?
        .iter()
        .map(|receipt| {
            (
                receipt["ruleId"].as_str().unwrap_or_default(),
                receipt["eventId"].as_str().unwrap_or_default(),
            )
        })
        .collect::<BTreeSet<_>>();
    let db_id = uuid(database.get("id"))?;
    let mut events = Vec::new();
    let mut scanned = 0_usize;
    for (index, rule) in definitions.iter().enumerate().skip(rule_index) {
        if !rule.get("enabled").and_then(Value::as_bool).unwrap_or(true)
            || rule["trigger"]["type"] != "schedule"
        {
            continue;
        }
        let owner = uuid(rule.get("ownerDeviceId"))?;
        if owner != device {
            continue;
        }
        validate_rule(rule, database)?;
        let schedule = Schedule::parse(rule)?;
        let rule_id = uuid(rule.get("id"))?;
        let last = schedule
            .end
            .map_or(cutoff.with_timezone(&schedule.zone).date_naive(), |end| {
                end.min(cutoff.with_timezone(&schedule.zone).date_naive())
            });
        let first = since
            .map(|since| {
                from_millis(since).map(|time| time.with_timezone(&schedule.zone).date_naive())
            })
            .transpose()?
            .unwrap_or(schedule.start)
            .max(schedule.start);
        let mut day = if index == rule_index {
            resume_date.unwrap_or(first).max(first)
        } else {
            first
        };
        while day <= last {
            if events.len() >= MAX_DUE || scanned >= MAX_SCAN {
                return Ok(
                    json!({"events":events,"hasMore":true,"cursor":{"signature":signature,"sinceUtcMs":since,"ruleIndex":index,"localDate":day.format("%Y-%m-%d").to_string()}}),
                );
            }
            scanned += 1;
            if let Some(slot) = schedule.occurrence(day)? {
                let event_id = derived_id("schedule", &[db_id, rule_id, &slot.to_string()]);
                if slot <= captured
                    && since.is_none_or(|since| slot > since)
                    && !completed.contains(&(rule_id, event_id.as_str()))
                {
                    let mut event =
                        json!({"id":event_id,"type":"schedule","scheduledForUtcMs":slot});
                    if let Some(row_id) = schedule_row(rule, database)? {
                        event["rowId"] = json!(row_id);
                    }
                    events.push(json!({"ruleId":rule_id,"event":event}));
                }
            }
            day = day.checked_add_days(Days::new(1)).ok_or_else(|| {
                error(
                    "invalid_time",
                    "Calendar scan exceeded its supported date range",
                )
            })?;
        }
    }
    Ok(json!({"events":events,"hasMore":false}))
}

struct Schedule {
    zone: Tz,
    zone_name: String,
    owner: String,
    start: NaiveDate,
    end: Option<NaiveDate>,
    time: NaiveTime,
    frequency: String,
    interval: i64,
    later: bool,
}
impl Schedule {
    fn parse(rule: &Value) -> ApiResult<Self> {
        let trigger = object(rule.get("trigger").ok_or_else(invalid)?)?;
        let zone_name = text(trigger.get("timeZone"))?.to_owned();
        let zone = zone_name.parse::<Tz>().map_err(|_| {
            error(
                "unsupported_timezone",
                "The IANA time zone is not supported by the pinned timezone database",
            )
        })?;
        let start = date(text(trigger.get("startDate"))?)?;
        let end = trigger
            .get("endDate")
            .filter(|v| !v.is_null())
            .map(|v| date(text(Some(v))?))
            .transpose()?;
        if end.is_some_and(|end| end < start) {
            return Err(error("invalid_schedule", "Schedule end precedes its start"));
        }
        let time_text = text(trigger.get("time"))?;
        if time_text.len() != 5 || time_text.as_bytes()[2] != b':' {
            return Err(error("invalid_schedule", "Schedule time must use HH:mm"));
        }
        let time = NaiveTime::parse_from_str(time_text, "%H:%M").map_err(|_| {
            error(
                "invalid_schedule",
                "Schedule time is not a valid wall-clock time",
            )
        })?;
        let frequency = text(trigger.get("frequency"))?.to_owned();
        if !matches!(
            frequency.as_str(),
            "daily" | "weekly" | "monthly" | "yearly"
        ) {
            return Err(error(
                "unsupported_schedule",
                "Schedule frequency is not supported",
            ));
        }
        let interval = trigger
            .get("interval")
            .and_then(Value::as_i64)
            .filter(|v| (1..=365).contains(v))
            .ok_or_else(|| {
                error(
                    "invalid_schedule",
                    "Schedule interval must be between 1 and 365",
                )
            })?;
        let ambiguous = match trigger.get("ambiguous") {
            None => "earlier",
            Some(value) => value
                .as_str()
                .ok_or_else(|| error("invalid_schedule", "Ambiguous-time policy must be text"))?,
        };
        let later = match ambiguous {
            "earlier" => false,
            "later" => true,
            _ => {
                return Err(error(
                    "invalid_schedule",
                    "Ambiguous local times require an earlier or later policy",
                ));
            }
        };
        if trigger
            .get("gap")
            .is_some_and(|value| value.as_str() != Some("skip"))
        {
            return Err(error(
                "invalid_schedule",
                "Missing DST wall-clock times must use the skip policy",
            ));
        }
        Ok(Self {
            zone,
            zone_name,
            owner: uuid(rule.get("ownerDeviceId"))?.to_owned(),
            start,
            end,
            time,
            frequency,
            interval,
            later,
        })
    }
    fn occurrence(&self, day: NaiveDate) -> ApiResult<Option<i64>> {
        if day < self.start || self.end.is_some_and(|end| day > end) {
            return Ok(None);
        }
        let days = day.signed_duration_since(self.start).num_days();
        let eligible = match self.frequency.as_str() {
            "daily" => days % self.interval == 0,
            "weekly" => days % (7 * self.interval) == 0,
            "monthly" => {
                let months = i64::from(day.year() - self.start.year()) * 12
                    + i64::from(day.month())
                    - i64::from(self.start.month());
                months % self.interval == 0 && day.day() == self.start.day()
            }
            "yearly" => {
                i64::from(day.year() - self.start.year()) % self.interval == 0
                    && day.month() == self.start.month()
                    && day.day() == self.start.day()
            }
            _ => false,
        };
        if !eligible {
            return Ok(None);
        }
        let occurrence = match self.zone.from_local_datetime(&day.and_time(self.time)) {
            chrono::LocalResult::Single(time) => Some(time),
            chrono::LocalResult::Ambiguous(a, b) => {
                Some(if self.later { a.max(b) } else { a.min(b) })
            }
            chrono::LocalResult::None => None,
        };
        Ok(occurrence.map(|time| time.timestamp_millis()))
    }
}

fn validate_database(database: &Value) -> ApiResult<()> {
    let db = object(database)?;
    if db
        .get("schemaVersion")
        .is_some_and(|value| !value.is_null() && value.as_f64() != Some(1.0))
    {
        return Err(error(
            "unsupported_schema",
            "Database schema is not supported",
        ));
    }
    uuid(db.get("id"))?;
    let fields = array(db.get("properties"))?;
    if fields.len() > 256 || rows(database)?.len() > MAX_ROWS || array(db.get("views"))?.len() > 128
    {
        return Err(error("size_limit", "Database collection limit was reached"));
    }
    unique_ids(fields, "duplicate_property")?;
    unique_ids(rows(database)?, "duplicate_row")?;
    for property in fields {
        object(property)?;
        nonempty(property.get("name"))?;
        nonempty(property.get("type"))?;
        if let Some(config) = property.get("config") {
            object(config)?;
        }
    }
    for row in rows(database)? {
        object(row)?;
        archived(row)?;
        if let Some(values) = row.get("values") {
            for (id, value) in object(values)? {
                if let Some(property) = fields.iter().find(|property| property["id"] == id.as_str())
                    && WRITABLE.contains(&text(property.get("type"))?)
                {
                    validate_value(property, value)?;
                }
            }
        }
    }
    let definitions = rules(database)?;
    if definitions.len() > MAX_RULES {
        return Err(error("rule_limit", "Automation rule limit was reached"));
    }
    unique_ids(definitions, "duplicate_rule")?;
    executions(database)?;
    Ok(())
}
fn validate_rule(rule: &Value, database: &Value) -> ApiResult<()> {
    object(rule)?;
    uuid(rule.get("id"))?;
    if !rule
        .get("version")
        .and_then(Value::as_u64)
        .is_some_and(|v| (1..=2_147_483_647).contains(&v))
    {
        return Err(error(
            "invalid_rule",
            "Rule version must be a positive bounded integer",
        ));
    }
    nonempty(rule.get("name"))?;
    if !rule.get("enabled").is_some_and(Value::is_boolean) {
        return Err(error("invalid_rule", "Rule enabled state must be boolean"));
    }
    let trigger = object(rule.get("trigger").ok_or_else(invalid)?)?;
    match text(trigger.get("type"))? {
        "manual" | "rowAdded" => {}
        "propertyChanged" => {
            let p = find_property(database, uuid(trigger.get("propertyId"))?)?;
            supported(p)?;
        }
        "schedule" => {
            Schedule::parse(rule)?;
            schedule_row(rule, database)?;
        }
        _ => {
            return Err(error(
                "unsupported_trigger",
                "Rule trigger is not supported",
            ));
        }
    }
    if let Some(condition) = rule.get("condition").filter(|v| !v.is_null()) {
        let mut budget = 0;
        validate_condition(condition, database, 0, &mut budget)?;
    }
    let actions = array(rule.get("actions"))?;
    if actions.is_empty() {
        return Err(error(
            "invalid_rule",
            "A rule must contain at least one action",
        ));
    }
    if actions.len() > MAX_ACTIONS {
        return Err(error("action_limit", "A rule exceeds its action limit"));
    }
    unique_ids(actions, "duplicate_action")?;
    for action in actions {
        object(action)?;
        match text(action.get("type"))? {
            "addRow" | "addRowFromTemplate" => {
                if action["type"] == "addRowFromTemplate" {
                    if trigger["type"] != "schedule" {
                        return Err(error(
                            "unsupported_action",
                            "Template rows require a schedule",
                        ));
                    }
                    let template_id = uuid(action.get("templateId"))?;
                    if (rule["archived"] != true || rule["enabled"] == true)
                        && !has_row_template(database, template_id)
                    {
                        return Err(error(
                            "missing_template",
                            "The scheduled row template was not found",
                        ));
                    }
                }
                let values = object(action.get("values").ok_or_else(invalid)?)?;
                for (id, value) in values {
                    let p = find_property(database, uuid(Some(&json!(id)))?)?;
                    validate_value(p, value)?;
                }
            }
            "setProperty" | "setStatus" => {
                let p = find_property(database, uuid(action.get("propertyId"))?)?;
                if action["type"] == "setStatus" && p["type"] != "status" {
                    return Err(error(
                        "invalid_value",
                        "Status actions require a status property",
                    ));
                }
                validate_value(p, action.get("value").ok_or_else(invalid)?)?;
                if let Some(id) = action.get("rowId") {
                    let target = find_row(database, uuid(Some(id))?)?;
                    if archived(target)? {
                        return Err(error("archived_row", "Actions cannot target archived rows"));
                    }
                } else if trigger.get("type").and_then(Value::as_str) == Some("schedule") {
                    return Err(error(
                        "missing_row",
                        "Schedule setters require an explicit row ID",
                    ));
                }
            }
            _ => return Err(error("unsupported_action", "Action type is not supported")),
        }
    }
    Ok(())
}
fn has_row_template(database: &Value, template_id: &str) -> bool {
    database
        .get("pivRowTemplates")
        .and_then(Value::as_object)
        .filter(|templates| {
            templates.len() == 2
                && templates.get("schemaVersion").and_then(Value::as_u64) == Some(1)
        })
        .and_then(|templates| templates.get("items"))
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|item| item["id"] == template_id))
}
fn validate_action_target(
    action: &Value,
    database: &Value,
    event_row: Option<&str>,
    scheduled: bool,
) -> ApiResult<()> {
    if matches!(
        action["type"].as_str(),
        Some("addRow" | "addRowFromTemplate")
    ) {
        return Ok(());
    }
    if scheduled && action.get("rowId").is_none() {
        return Err(error(
            "missing_row",
            "Schedule setters require an explicit row ID",
        ));
    }
    let row = find_row(database, target_row(action, event_row)?)?;
    if archived(row)? {
        return Err(error("archived_row", "Actions cannot change archived rows"));
    }
    Ok(())
}
fn schedule_row<'a>(rule: &'a Value, database: &Value) -> ApiResult<Option<&'a str>> {
    let row_id = rule
        .get("trigger")
        .and_then(|trigger| trigger.get("rowId"))
        .filter(|row| !row.is_null());
    if row_id.is_none()
        && rule
            .get("condition")
            .is_some_and(|condition| !condition.is_null())
    {
        return Err(error(
            "missing_row",
            "Schedule conditions require a fixed trigger row ID",
        ));
    }
    let row_id = row_id.map(|row| uuid(Some(row))).transpose()?;
    if let Some(row_id) = row_id
        && archived(find_row(database, row_id)?)?
    {
        return Err(error(
            "archived_row",
            "Schedule condition rows must be live",
        ));
    }
    Ok(row_id)
}
fn target_row<'a>(action: &'a Value, event_row: Option<&'a str>) -> ApiResult<&'a str> {
    action
        .get("rowId")
        .map(|v| uuid(Some(v)))
        .transpose()?
        .or(event_row)
        .ok_or_else(|| error("missing_row", "Action requires a row ID"))
}
fn supported(property: &Value) -> ApiResult<&str> {
    let ty = text(property.get("type"))?;
    if !WRITABLE.contains(&ty) {
        return Err(error(
            "unsupported_property",
            "This property type is not writable by workspace actions",
        ));
    }
    Ok(ty)
}

fn validate_value(property: &Value, value: &Value) -> ApiResult<()> {
    let ty = supported(property)?;
    if value.is_null() {
        return Ok(());
    }
    let invalid_value = || {
        error(
            "invalid_value",
            "Action or condition value does not match the property type or options",
        )
    };
    match ty {
        "title" | "text" | "phone" => {
            if !value.is_string() {
                return Err(invalid_value());
            }
        }
        "number" => {
            if !value.as_f64().is_some_and(f64::is_finite) {
                return Err(invalid_value());
            }
        }
        "checkbox" => {
            if !value.is_boolean() {
                return Err(invalid_value());
            }
        }
        "status" | "select" => option(property, value)?,
        "multiSelect" => {
            let items = value.as_array().ok_or_else(invalid_value)?;
            let mut seen = BTreeSet::new();
            for item in items {
                let s = item.as_str().ok_or_else(invalid_value)?;
                if !seen.insert(s) {
                    return Err(invalid_value());
                }
                option(property, item)?;
            }
        }
        "date" => {
            normalized_date(value)?;
        }
        "url" => {
            let value = value.as_str().ok_or_else(invalid_value)?;
            if !value.is_empty() {
                let (scheme, remaining) = value.split_once("://").ok_or_else(invalid_value)?;
                if !matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
                    || remaining.chars().any(char::is_whitespace)
                {
                    return Err(invalid_value());
                }
                let authority = remaining.split(['/', '?', '#']).next().unwrap_or_default();
                let host = authority.rsplit('@').next().unwrap_or_default();
                if host.is_empty()
                    || host.starts_with(':')
                    || host.chars().any(|c| c.is_control() || c == '\\')
                {
                    return Err(invalid_value());
                }
            }
        }
        "email" => {
            static EMAIL: OnceLock<Regex> = OnceLock::new();
            let value = value.as_str().ok_or_else(invalid_value)?;
            if !value.is_empty()
                && !EMAIL
                    .get_or_init(|| {
                        Regex::new(r"^[^@\s]+@[^@\s]+\.[^@\s]+$").expect("constant email pattern")
                    })
                    .is_match(value)
            {
                return Err(invalid_value());
            }
        }
        _ => return Err(invalid_value()),
    }
    Ok(())
}
fn option(property: &Value, value: &Value) -> ApiResult<()> {
    let s = value
        .as_str()
        .ok_or_else(|| error("invalid_value", "Selection values must be text"))?;
    if s.is_empty() {
        return Ok(());
    }
    if let Some(options) = property
        .get("config")
        .and_then(|c| c.get("options"))
        .filter(|v| !v.is_null())
    {
        let options = options
            .as_array()
            .ok_or_else(|| error("invalid_value", "Property options must be a list"))?;
        if !options.iter().any(|option| {
            option == value || option.get("id") == Some(value) || option.get("name") == Some(value)
        }) {
            return Err(error("invalid_value", "Selection option does not exist"));
        }
    }
    Ok(())
}
fn validate_condition(
    node: &Value,
    database: &Value,
    depth: usize,
    budget: &mut usize,
) -> ApiResult<()> {
    *budget += 1;
    if depth > 16 || *budget > 128 {
        return Err(error(
            "condition_limit",
            "Condition depth or node budget was exceeded",
        ));
    }
    let object = object(node)?;
    let operators = ["and", "or", "not"]
        .into_iter()
        .filter(|key| object.contains_key(*key))
        .collect::<Vec<_>>();
    if !operators.is_empty() {
        if operators.len() != 1
            || object.contains_key("propertyId")
            || object.contains_key("operator")
        {
            return Err(error(
                "invalid_condition",
                "Condition structure is ambiguous",
            ));
        }
        let key = operators[0];
        if key == "not" {
            return validate_condition(&node[key], database, depth + 1, budget);
        }
        let children = node[key]
            .as_array()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| error("invalid_condition", "Logical groups require conditions"))?;
        for child in children {
            validate_condition(child, database, depth + 1, budget)?;
        }
        return Ok(());
    }
    let property = find_property(database, uuid(node.get("propertyId"))?)?;
    let ty = supported(property)?;
    match text(node.get("operator"))? {
        "isEmpty" | "isNotEmpty" => Ok(()),
        "eq" | "notEq" => validate_value(property, node.get("value").ok_or_else(invalid)?),
        "contains" => {
            let value = node.get("value").ok_or_else(invalid)?;
            if ty == "multiSelect" {
                validate_value(property, &json!([value]))
            } else if matches!(
                ty,
                "title" | "text" | "phone" | "url" | "email" | "status" | "select"
            ) && value.is_string()
            {
                Ok(())
            } else {
                Err(error(
                    "invalid_value",
                    "Contains requires a text or selection operand",
                ))
            }
        }
        _ => Err(error(
            "unsupported_condition",
            "Condition operator is not supported",
        )),
    }
}
fn condition_matches(node: &Value, row: &Value, database: &Value) -> ApiResult<bool> {
    if let Some(children) = node.get("and").and_then(Value::as_array) {
        for child in children {
            if !condition_matches(child, row, database)? {
                return Ok(false);
            }
        }
        return Ok(true);
    }
    if let Some(children) = node.get("or").and_then(Value::as_array) {
        for child in children {
            if condition_matches(child, row, database)? {
                return Ok(true);
            }
        }
        return Ok(false);
    }
    if let Some(child) = node.get("not") {
        return Ok(!condition_matches(child, row, database)?);
    }
    let property_id = uuid(node.get("propertyId"))?;
    let value = cell(row, property_id);
    let compare = node.get("value").unwrap_or(&Value::Null);
    Ok(match text(node.get("operator"))? {
        "eq" => typed_equal(find_property(database, property_id)?, value, compare)?,
        "notEq" => !typed_equal(find_property(database, property_id)?, value, compare)?,
        "isEmpty" => empty(value),
        "isNotEmpty" => !empty(value),
        "contains" => match (value, compare) {
            (Value::String(a), Value::String(b)) => a.contains(b),
            (Value::Array(items), _) => items.contains(compare),
            _ => false,
        },
        _ => false,
    })
}
fn typed_equal(property: &Value, value: &Value, compare: &Value) -> ApiResult<bool> {
    if value.is_null() || compare.is_null() {
        return Ok(value == compare);
    }
    match supported(property)? {
        "number" => Ok(match (value.as_number(), compare.as_number()) {
            (Some(left), Some(right)) => numbers_equal(left, right),
            _ => false,
        }),
        "date" => Ok(normalized_date(value)? == normalized_date(compare)?),
        _ => Ok(value == compare),
    }
}
fn numbers_equal(left: &Number, right: &Number) -> bool {
    if let (Some(left), Some(right)) = (left.as_i64(), right.as_i64()) {
        return left == right;
    }
    if let (Some(left), Some(right)) = (left.as_u64(), right.as_u64()) {
        return left == right;
    }
    let (integer, float) = if left.is_f64() {
        (right, left)
    } else if right.is_f64() {
        (left, right)
    } else {
        return false;
    };
    let Some(float) = float.as_f64() else {
        return false;
    };
    if integer.is_f64() {
        return integer.as_f64() == Some(float);
    }
    if float.fract() != 0.0 {
        return false;
    }
    if let Some(integer) = integer.as_i64() {
        // The upper bound is exclusive: casting 2^63 saturates to i64::MAX.
        (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&float)
            && float as i64 == integer
    } else if let Some(integer) = integer.as_u64() {
        (0.0..18_446_744_073_709_551_616.0).contains(&float) && float as u64 == integer
    } else {
        false
    }
}
fn normalized_date(value: &Value) -> ApiResult<(DateTime<Utc>, Option<DateTime<Utc>>, bool)> {
    let invalid_date = || error("invalid_value", "A valid database date is required");
    let start = value
        .as_str()
        .or_else(|| {
            value
                .get("start")
                .filter(|v| !v.is_null())
                .or_else(|| value.get("dateISO"))
                .and_then(Value::as_str)
        })
        .ok_or_else(invalid_date)?;
    let first = iso_date(start)?;
    let last = value
        .get("end")
        .filter(|v| !v.is_null())
        .map(|v| iso_date(v.as_str().ok_or_else(invalid_date)?))
        .transpose()?;
    if last.is_some_and(|last| last < first)
        || value
            .get("timeZone")
            .is_some_and(|v| !v.is_null() && !v.is_string())
    {
        return Err(invalid_date());
    }
    Ok((first, last, !start.contains('T')))
}
fn empty(value: &Value) -> bool {
    value.is_null()
        || value.as_str().is_some_and(str::is_empty)
        || value.as_array().is_some_and(Vec::is_empty)
        || value.as_object().is_some_and(Map::is_empty)
}

fn iso_date(value: &str) -> ApiResult<DateTime<Utc>> {
    static ISO: OnceLock<Regex> = OnceLock::new();
    let regex=ISO.get_or_init(||Regex::new(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]{1,6}))?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$").expect("constant ISO pattern"));
    let captures = regex
        .captures(value)
        .ok_or_else(|| error("invalid_value", "A valid ISO date is required"))?;
    let part = |index| {
        captures
            .get(index)
            .and_then(|v| v.as_str().parse::<u32>().ok())
            .unwrap_or(0)
    };
    let day = NaiveDate::from_ymd_opt(part(1) as i32, part(2), part(3))
        .ok_or_else(|| error("invalid_value", "Calendar date is not valid"))?;
    let micro = captures
        .get(7)
        .map(|v| format!("{:0<6}", v.as_str()).parse::<u32>().unwrap_or(0))
        .unwrap_or(0);
    let naive = day
        .and_hms_micro_opt(part(4), part(5), part(6), micro)
        .ok_or_else(|| error("invalid_value", "Clock time is not valid"))?;
    let offset = if let Some(zone) = captures.get(8).map(|v| v.as_str()).filter(|z| *z != "Z") {
        let hours = zone[1..3].parse::<i32>().unwrap_or(99);
        let minutes = zone[4..6].parse::<i32>().unwrap_or(99);
        if hours > 23 || minutes > 59 {
            return Err(error("invalid_value", "UTC offset is not valid"));
        }
        (hours * 3600 + minutes * 60) * if zone.starts_with('-') { -1 } else { 1 }
    } else {
        0
    };
    naive
        .and_utc()
        .checked_sub_signed(chrono::TimeDelta::seconds(i64::from(offset)))
        .ok_or_else(|| error("invalid_value", "Date is outside its supported range"))
}
fn date(value: &str) -> ApiResult<NaiveDate> {
    if value.len() != 10
        || !value.as_bytes().iter().enumerate().all(|(i, b)| {
            if i == 4 || i == 7 {
                *b == b'-'
            } else {
                b.is_ascii_digit()
            }
        })
    {
        return Err(error(
            "invalid_schedule",
            "Schedule date must use YYYY-MM-DD",
        ));
    }
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| error("invalid_schedule", "Schedule calendar date is invalid"))
}
fn timestamp(value: Option<&Value>) -> ApiResult<i64> {
    let timestamp = value.and_then(Value::as_i64).ok_or_else(|| {
        error(
            "invalid_time",
            "UTC epoch milliseconds must be an i64 integer",
        )
    })?;
    from_millis(timestamp)?;
    Ok(timestamp)
}
fn from_millis(value: i64) -> ApiResult<DateTime<Utc>> {
    DateTime::<Utc>::from_timestamp_millis(value)
        .filter(|date| (0..=9999).contains(&date.year()))
        .ok_or_else(|| {
            error(
                "invalid_time",
                "UTC timestamp is outside years 0000 to 9999",
            )
        })
}
fn object(value: &Value) -> ApiResult<&Map<String, Value>> {
    value.as_object().ok_or_else(invalid)
}
fn text(value: Option<&Value>) -> ApiResult<&str> {
    value.and_then(Value::as_str).ok_or_else(invalid)
}
fn nonempty(value: Option<&Value>) -> ApiResult<&str> {
    let value = text(value)?;
    if value.trim().is_empty() {
        return Err(invalid());
    }
    Ok(value)
}
fn uuid(value: Option<&Value>) -> ApiResult<&str> {
    let value = value.ok_or_else(|| error("invalid_id", "A UUID is required"))?;
    if !valid_id(value) {
        return Err(error("invalid_id", "A canonical UUID is required"));
    }
    Ok(value.as_str().unwrap_or_default())
}
fn array(value: Option<&Value>) -> ApiResult<&[Value]> {
    match value {
        None => Ok(&[]),
        Some(value) => value.as_array().map(Vec::as_slice).ok_or_else(invalid),
    }
}
fn rows(database: &Value) -> ApiResult<&[Value]> {
    array(database.get("rows"))
}
fn rules(database: &Value) -> ApiResult<&[Value]> {
    array(database.get("automationRules"))
}
fn find_property<'a>(database: &'a Value, id: &str) -> ApiResult<&'a Value> {
    array(database.get("properties"))?
        .iter()
        .find(|p| p["id"] == id)
        .ok_or_else(|| {
            error(
                "missing_property",
                "Action or condition property was deleted",
            )
        })
}
fn find_row<'a>(database: &'a Value, id: &str) -> ApiResult<&'a Value> {
    rows(database)?
        .iter()
        .find(|r| r["id"] == id)
        .ok_or_else(|| error("missing_row", "Event or action row was deleted"))
}
fn cell<'a>(row: &'a Value, id: &str) -> &'a Value {
    row.get("values")
        .and_then(|values| values.get(id))
        .unwrap_or(&Value::Null)
}
fn archived(row: &Value) -> ApiResult<bool> {
    match row.get("archived") {
        None => Ok(false),
        Some(value) => value.as_bool().ok_or_else(invalid),
    }
}
fn unique_ids(values: &[Value], code: &'static str) -> ApiResult<()> {
    let mut ids = BTreeSet::new();
    for value in values {
        if !ids.insert(uuid(value.get("id"))?) {
            return Err(error(code, "Duplicate identity in a database collection"));
        }
    }
    Ok(())
}
fn executions(database: &Value) -> ApiResult<&[Value]> {
    let receipts = array(database.get("automationExecutions"))?;
    if receipts.len() > MAX_RECEIPTS {
        return Err(error(
            "receipt_limit",
            "Automation receipt limit was reached",
        ));
    }
    let mut ids = BTreeSet::new();
    for receipt in receipts {
        object(receipt)?;
        for key in ["id", "ruleId", "eventId", "inputRevision", "deviceId"] {
            uuid(receipt.get(key))?;
        }
        if !ids.insert(uuid(receipt.get("id"))?) {
            return Err(error("invalid_receipt", "Duplicate execution receipt ID"));
        }
        if receipt["id"]
            != derived_id(
                "execution",
                &[
                    uuid(database.get("id"))?,
                    uuid(receipt.get("ruleId"))?,
                    uuid(receipt.get("eventId"))?,
                ],
            )
        {
            return Err(error(
                "invalid_receipt",
                "Execution receipt identity does not match its database, rule and event",
            ));
        }
        timestamp(receipt.get("capturedAtUtcMs"))?;
        for key in ["eventDigest", "ruleDigest"] {
            let value = text(receipt.get(key))?;
            if value.len() != 64
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_digit() || matches!(b, b'a'..=b'f'))
            {
                return Err(error(
                    "invalid_receipt",
                    "Execution receipt hash is invalid",
                ));
            }
        }
        if !receipt
            .get("ruleVersion")
            .and_then(Value::as_u64)
            .is_some_and(|v| v > 0)
            || !matches!(
                receipt.get("status").and_then(Value::as_str),
                Some("completed" | "skipped")
            )
        {
            return Err(error(
                "invalid_receipt",
                "Execution receipt metadata is invalid",
            ));
        }
        array(receipt.get("actionResults"))?;
    }
    Ok(receipts)
}
fn digest(value: &Value) -> String {
    Sha256::digest(value.to_string().as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
fn derived_id(domain: &str, parts: &[&str]) -> String {
    let value = json!(["ink-vault-workspace-actions-v1", domain, parts]);
    let hash = Sha256::digest(value.to_string().as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}
fn bounded(value: &Value) -> ApiResult<()> {
    fn visit(value: &Value, depth: usize, nodes: &mut usize, units: &mut usize) -> ApiResult<()> {
        *nodes += 1;
        if depth > 64 || *nodes > 200_000 {
            return Err(error(
                "size_limit",
                "JSON nesting or node limit was exceeded",
            ));
        }
        match value {
            Value::String(value) => *units = units.saturating_add(value.len()),
            Value::Array(values) => {
                for value in values {
                    visit(value, depth + 1, nodes, units)?;
                }
            }
            Value::Object(values) => {
                for (key, value) in values {
                    *units = units.saturating_add(key.len());
                    visit(value, depth + 1, nodes, units)?;
                }
            }
            _ => {}
        }
        if *units > 8_000_000 {
            return Err(error("size_limit", "JSON text size limit was exceeded"));
        }
        Ok(())
    }
    visit(value, 0, &mut 0, &mut 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::DateTime;
    use serde_json::json;

    fn id(n: u32) -> String {
        format!("{n:08x}-0000-4000-8000-000000000000")
    }
    fn utc(text: &str) -> i64 {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .timestamp_millis()
    }
    fn rule() -> Value {
        json!({"id":id(20),"version":1,"name":"Create task","enabled":true,
          "trigger":{"type":"manual"},"future":{"keep":[1]},
          "actions":[{"id":id(21),"type":"addRow","values":{id(2):"New task",id(3):"todo"}}]})
    }
    fn database() -> Value {
        json!({"schemaVersion":1,"id":id(1),
          "properties":[
            {"id":id(2),"name":"Name","type":"title","config":{},"future":{"keep":true}},
            {"id":id(3),"name":"Status","type":"status","config":{"options":[{"id":"todo","name":"Todo"},{"id":"doing","name":"Doing"},{"id":"done","name":"Done"}]}},
            {"id":id(4),"name":"Count","type":"number","config":{}},
            {"id":id(5),"name":"Checked","type":"checkbox","config":{}}],
          "rows":[{"id":id(10),"values":{id(2):"Original",id(3):"todo",id(4):1},"archived":false,
            "body":{"version":1,"blocks":[],"future":{"keep":"body"}},"future":{"keep":[2]}}],
          "views":[],"automationRules":[rule()],"sourceEntityId":"original.pdf","summary":"manual summary",
          "forms":[{"opaque":{"nested":[3]}}],"futureRoot":{"keep":[4]}})
    }
    fn request(db: Value) -> Value {
        json!({"database":db,"ruleId":id(20),"event":{"id":id(30),"type":"manual","rowId":id(10)},
          "inputRevision":id(40),"deviceId":id(50),"capturedAtUtcMs":utc("2026-10-30T10:00:00Z")})
    }
    fn run(request: &Value) -> Value {
        match apply(request.as_object().unwrap()) {
            Ok(value) => value,
            Err(e) => panic!("{}: {}", e.code, e.message),
        }
    }
    fn fail(request: &Value, code: &str) {
        match apply(request.as_object().unwrap()) {
            Err(e) => assert_eq!(e.code, code),
            Ok(value) => panic!("Expected {code}, received {value}"),
        }
    }
    fn set_action(property: u32, value: Value) -> Value {
        json!({"id":id(21),"type":"setProperty","propertyId":id(property),"value":value})
    }
    fn property_event(db: Value) -> Value {
        let mut value = request(db);
        value.as_object_mut().unwrap().remove("ruleId");
        value["event"] = json!({"id":id(30),"type":"propertyChanged","rowId":id(10),"propertyId":id(3),"oldValue":"todo","value":"doing"});
        value
    }
    fn scheduled_rule(zone: &str, date: &str, time: &str) -> Value {
        let mut value = rule();
        value["ownerDeviceId"] = json!(id(50));
        value["trigger"] = json!({"type":"schedule","frequency":"daily","interval":1,"timeZone":zone,
          "startDate":date,"time":time,"ambiguous":"earlier","gap":"skip"});
        value
    }
    fn due(db: Value, captured: &str) -> Value {
        json!({"mode":"due","database":db,"deviceId":id(50),"capturedAtUtcMs":utc(captured)})
    }

    #[test]
    fn manual_adds_typed_row_and_atomic_receipt_preserving_unknown_json() {
        let input = request(database());
        let original = input.clone();
        let result = run(&input);
        assert_eq!(input, original);
        assert_eq!(result["database"]["rows"].as_array().unwrap().len(), 2);
        assert_eq!(result["receipts"].as_array().unwrap().len(), 1);
        assert_eq!(result["duplicate"], false);
        assert_eq!(result["changed"], true);
        let receipt = &result["receipts"][0];
        assert_eq!(receipt["inputRevision"], id(40));
        assert_eq!(receipt["deviceId"], id(50));
        assert_eq!(receipt["capturedAtUtcMs"], input["capturedAtUtcMs"]);
        assert_eq!(receipt["ruleVersion"], 1);
        assert_eq!(
            receipt["actionResults"][0]["rowId"],
            result["database"]["rows"][1]["id"]
        );
        assert_eq!(result["database"]["automationExecutions"][0], *receipt);
        assert_eq!(
            result["database"]["rows"][1]["id"]
                .as_str()
                .unwrap()
                .as_bytes()[14],
            b'8'
        );
        for key in [
            "sourceEntityId",
            "summary",
            "forms",
            "futureRoot",
            "properties",
            "automationRules",
        ] {
            assert_eq!(result["database"][key], original["database"][key]);
        }
        assert_eq!(
            result["database"]["rows"][0],
            original["database"]["rows"][0]
        );
    }

    #[test]
    fn preparation_retry_is_deterministic_and_duplicate_uses_original_metadata_after_rule_edit() {
        let input = request(database());
        let first = run(&input);
        assert_eq!(run(&input), first);
        let mut retry = request(first["database"].clone());
        retry["database"]["automationRules"][0]["version"] = json!(2);
        retry["database"]["automationRules"][0]["enabled"] = json!(false);
        retry["inputRevision"] = json!(id(41));
        retry["capturedAtUtcMs"] = json!(utc("2026-11-01T10:00:00Z"));
        let result = run(&retry);
        assert_eq!(result["duplicate"], true);
        assert_eq!(result["changed"], false);
        assert_eq!(result["receipts"], first["receipts"]);
        assert_eq!(result["database"], retry["database"]);
    }

    #[test]
    fn same_event_different_payload_or_manual_rule_is_rejected() {
        let first = run(&request(database()));
        let mut retry = request(first["database"].clone());
        retry["event"]["rowId"] = json!(id(11));
        fail(&retry, "event_conflict");
        retry["event"]["rowId"] = json!(id(10));
        retry["ruleId"] = json!(id(22));
        fail(&retry, "event_conflict");
    }

    #[test]
    fn setters_preserve_row_identity_body_and_unknown_fields() {
        let mut input = request(database());
        input["database"]["automationRules"][0]["actions"] = json!([
          {"id":id(21),"type":"setStatus","propertyId":id(3),"value":"done"},
          {"id":id(22),"type":"setProperty","propertyId":id(4),"value":12.5}]);
        let result = run(&input);
        let row = &result["database"]["rows"][0];
        assert_eq!(row["id"], id(10));
        assert_eq!(row["values"][id(3)], "done");
        assert_eq!(row["values"][id(4)], 12.5);
        assert_eq!(row["body"], input["database"]["rows"][0]["body"]);
        assert_eq!(row["future"], input["database"]["rows"][0]["future"]);
    }

    #[test]
    fn validates_all_eleven_writable_raw_types_and_selection_options() {
        let samples = [
            ("title", json!("Name")),
            ("text", json!("<script>inert</script>")),
            ("number", json!(1.5)),
            ("status", json!("one")),
            ("select", json!("one")),
            ("multiSelect", json!(["one"])),
            (
                "date",
                json!({"start":"2026-10-30","end":"2026-10-31","timeZone":"Asia/Seoul"}),
            ),
            ("checkbox", json!(false)),
            ("url", json!("https://example.com")),
            ("email", json!("a@example.com")),
            ("phone", json!("+82 10")),
        ];
        for (ty, value) in samples {
            let mut input = request(database());
            input["database"]["properties"].as_array_mut().unwrap().push(json!({"id":id(60),"name":ty,"type":ty,"config":{"options":[{"id":"one","name":"First"}]}}));
            input["database"]["automationRules"][0]["actions"] =
                json!([set_action(60, value.clone())]);
            assert_eq!(run(&input)["database"]["rows"][0]["values"][id(60)], value);
        }
    }

    #[test]
    fn unsupported_properties_actions_and_invalid_typed_values_fail_without_mutation() {
        for ty in ["formula", "rollup", "files", "people", "relation", "future"] {
            let mut input = request(database());
            input["database"]["properties"]
                .as_array_mut()
                .unwrap()
                .push(json!({"id":id(60),"name":ty,"type":ty,"config":{}}));
            input["database"]["automationRules"][0]["actions"] =
                json!([set_action(60, json!(null))]);
            let before = input.clone();
            fail(&input, "unsupported_property");
            assert_eq!(input, before);
        }
        let mut input = request(database());
        input["database"]["automationRules"][0]["actions"] = json!([set_action(4, json!("12"))]);
        fail(&input, "invalid_value");
        input["database"]["automationRules"][0]["actions"][0]["type"] = json!("shell");
        fail(&input, "unsupported_action");
    }

    #[test]
    fn later_action_failure_leaves_original_and_receipts_untouched() {
        let mut input = request(database());
        input["database"]["automationRules"][0]["actions"]
            .as_array_mut()
            .unwrap()
            .push(set_action(4, json!("bad")));
        input["database"]["automationRules"][0]["actions"][1]["id"] = json!(id(22));
        let before = input.clone();
        fail(&input, "invalid_value");
        assert_eq!(input, before);
        assert!(input["database"].get("automationExecutions").is_none());
    }

    #[test]
    fn missing_deleted_archived_targets_and_row_identity_collision_reject() {
        let mut input = request(database());
        input["database"]["automationRules"][0]["actions"] = json!([set_action(999, json!(1))]);
        fail(&input, "missing_property");
        input["database"]["automationRules"][0]["actions"] = json!([set_action(4, json!(1))]);
        input["event"]["rowId"] = json!(id(999));
        fail(&input, "missing_row");
        input["event"]["rowId"] = json!(id(10));
        input["database"]["rows"][0]["archived"] = json!(true);
        fail(&input, "archived_row");
        let first = run(&request(database()));
        let mut collision = request(database());
        collision["database"]["rows"]
            .as_array_mut()
            .unwrap()
            .push(first["database"]["rows"][1].clone());
        fail(&collision, "row_identity_conflict");
    }

    #[test]
    fn property_batch_matches_frozen_event_before_prior_rule_changes_it_and_retries() {
        let mut db = database();
        db["rows"][0]["values"][id(3)] = json!("doing");
        let mut first = rule();
        first["trigger"] = json!({"type":"propertyChanged","propertyId":id(3)});
        first["condition"] = json!({"propertyId":id(3),"operator":"eq","value":"doing"});
        first["actions"] = json!([set_action(3, json!("done"))]);
        let mut second = first.clone();
        second["id"] = json!(id(22));
        second["actions"] = rule()["actions"].clone();
        db["automationRules"] = json!([first, second]);
        let input = property_event(db);
        let result = run(&input);
        assert_eq!(result["database"]["rows"].as_array().unwrap().len(), 2);
        assert_eq!(result["database"]["rows"][0]["values"][id(3)], "done");
        assert_eq!(result["receipts"].as_array().unwrap().len(), 2);
        let mut retry = input.clone();
        retry["database"] = result["database"].clone();
        let replay = run(&retry);
        assert_eq!(replay["duplicate"], true);
        assert_eq!(replay["receipts"], result["receipts"]);
    }

    #[test]
    fn stale_property_event_does_not_execute_and_event_values_are_typed() {
        let mut input = property_event(database());
        input["database"]["automationRules"][0]["trigger"] =
            json!({"type":"propertyChanged","propertyId":id(3)});
        fail(&input, "stale_event");
        input["event"]["value"] = json!(12);
        fail(&input, "invalid_value");
    }

    #[test]
    fn boolean_conditions_use_typed_raw_values_and_record_skipped_results() {
        let mut input = request(database());
        input["database"]["automationRules"][0]["condition"] = json!({"and":[
          {"propertyId":id(2),"operator":"contains","value":"Orig"},
          {"not":{"propertyId":id(4),"operator":"eq","value":1}}]});
        let result = run(&input);
        assert_eq!(result["receipts"][0]["status"], "skipped");
        assert_eq!(result["database"]["rows"], input["database"]["rows"]);
        let mut bad = input;
        bad["database"]["automationRules"][0]["condition"] =
            json!({"propertyId":id(4),"operator":"eq","value":"1"});
        fail(&bad, "invalid_value");
    }

    fn assert_typed_condition(ty: &str, value: Value, compare: Value, equal: bool) {
        for (operator, matches) in [("eq", equal), ("notEq", !equal)] {
            let mut input = request(database());
            input["database"]["properties"][2]["type"] = json!(ty);
            input["database"]["rows"][0]["values"][id(4)] = value.clone();
            input["database"]["automationRules"][0]["condition"] =
                json!({"propertyId":id(4),"operator":operator,"value":compare});
            let original = input.clone();
            let result = run(&input);
            assert_eq!(
                result["receipts"][0]["status"],
                if matches { "completed" } else { "skipped" },
                "{ty}: {value} {operator} {compare}"
            );
            assert_eq!(
                result["database"]["rows"].as_array().unwrap().len(),
                if matches { 2 } else { 1 }
            );
            assert_eq!(input, original);
        }
    }

    #[test]
    fn typed_number_conditions_equate_integer_and_float_representations() {
        for (value, compare) in [
            (json!(1), json!(1.0)),
            (json!(1.0), json!(1)),
            (json!(-1), json!(-1.0)),
            (json!(0), json!(-0.0)),
            (json!(1.5), json!(1.5)),
        ] {
            assert_typed_condition("number", value, compare, true);
        }
    }

    #[test]
    fn typed_number_conditions_preserve_large_integer_precision_and_cast_boundaries() {
        for (value, compare, equal) in [
            (
                json!(9_007_199_254_740_991_i64),
                json!(9_007_199_254_740_991.0),
                true,
            ),
            (
                json!(9_007_199_254_740_993_i64),
                json!(9_007_199_254_740_992.0),
                false,
            ),
            (
                json!(9_007_199_254_740_992_i64),
                json!(9_007_199_254_740_992.0),
                true,
            ),
            (json!(i64::MAX), json!(9_223_372_036_854_775_808.0), false),
            (json!(i64::MIN), json!(-9_223_372_036_854_775_808.0), true),
            (
                json!(-9_223_372_036_854_775_807_i64),
                json!(-9_223_372_036_854_775_808.0),
                false,
            ),
            (
                json!(9_223_372_036_854_775_808_u64),
                json!(9_223_372_036_854_775_808.0),
                true,
            ),
            (json!(u64::MAX), json!(18_446_744_073_709_551_616.0), false),
            (
                json!(18_446_744_073_709_549_568_u64),
                json!(18_446_744_073_709_549_568.0),
                true,
            ),
            (json!(1), json!(1.5), false),
            (json!(1.5), json!(1.6), false),
            (json!(-1), json!(u64::MAX), false),
        ] {
            assert_typed_condition("number", value.clone(), compare.clone(), equal);
            assert_typed_condition("number", compare, value, equal);
        }
    }

    #[test]
    fn typed_date_conditions_equate_day_strings_and_supported_maps() {
        for (value, compare) in [
            (json!("2026-10-30"), json!({"start":"2026-10-30"})),
            (
                json!({"dateISO":"2026-10-30"}),
                json!({"start":"2026-10-30","end":null,"timeZone":"Asia/Seoul","future":{"keep":true}}),
            ),
            (Value::Null, Value::Null),
        ] {
            assert_typed_condition("date", value.clone(), compare.clone(), true);
            assert_typed_condition("date", compare, value, true);
        }
    }

    #[test]
    fn typed_date_conditions_use_date_iso_when_start_is_null() {
        assert_typed_condition(
            "date",
            json!({"start":null,"dateISO":"2026-10-30"}),
            json!("2026-10-30"),
            true,
        );
    }

    #[test]
    fn typed_date_conditions_equate_offsets_and_full_precision_instants() {
        for (value, compare) in [
            (
                json!("2026-10-30T09:00:00+09:00"),
                json!({"start":"2026-10-30T00:00:00Z"}),
            ),
            (
                json!({"start":"2026-10-30T00:00:00.1Z"}),
                json!({"dateISO":"2026-10-29T20:00:00.100000-04:00"}),
            ),
            (
                json!({"start":"2026-10-30T09:00+09:00","end":"2026-10-30T10:00+09:00"}),
                json!({"start":"2026-10-30T00:00:00Z","end":"2026-10-30T01:00:00Z"}),
            ),
        ] {
            assert_typed_condition("date", value.clone(), compare.clone(), true);
            assert_typed_condition("date", compare, value, true);
        }
    }

    #[test]
    fn typed_date_conditions_keep_all_day_and_microsecond_differences() {
        for (value, compare) in [
            (json!("2026-10-30"), json!("2026-10-30T00:00:00Z")),
            (
                json!("2026-10-30T00:00:00.000001Z"),
                json!("2026-10-30T00:00:00.000002Z"),
            ),
            (Value::Null, json!("2026-10-30")),
        ] {
            assert_typed_condition("date", value.clone(), compare.clone(), false);
            assert_typed_condition("date", compare, value, false);
        }
    }

    #[test]
    fn typed_date_conditions_keep_range_end_presence_and_value() {
        for (value, compare) in [
            (
                json!({"start":"2026-10-30","end":"2026-10-31"}),
                json!({"start":"2026-10-30","end":"2026-11-01"}),
            ),
            (
                json!({"start":"2026-10-30"}),
                json!({"start":"2026-10-30","end":"2026-10-30"}),
            ),
        ] {
            assert_typed_condition("date", value.clone(), compare.clone(), false);
            assert_typed_condition("date", compare, value, false);
        }
    }

    #[test]
    fn typed_conditions_apply_inside_nested_boolean_trees() {
        let mut input = request(database());
        input["database"]["properties"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":id(6),"name":"Date","type":"date","config":{}}));
        input["database"]["rows"][0]["values"][id(6)] = json!({"start":"2026-10-30"});
        input["database"]["automationRules"][0]["condition"] = json!({"and":[
            {"propertyId":id(4),"operator":"eq","value":1.0},
            {"or":[
                {"propertyId":id(6),"operator":"eq","value":"2026-10-30"},
                {"not":{"propertyId":id(4),"operator":"eq","value":1}}
            ]}
        ]});
        let result = run(&input);
        assert_eq!(result["receipts"][0]["status"], "completed");
        assert_eq!(result["database"]["rows"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn automatic_origin_and_rule_lineage_cycles_are_explicitly_rejected() {
        let mut input = request(database());
        input["event"]["origin"] = json!("automation");
        fail(&input, "automation_cycle");
        input["event"]["origin"] = json!("user");
        input["event"]["lineage"] = json!([id(20)]);
        fail(&input, "automation_cycle");
    }

    #[test]
    fn invalid_ids_times_action_counts_and_json_limits_reject() {
        let mut input = request(database());
        input["inputRevision"] = json!("placeholder");
        fail(&input, "invalid_id");
        input["inputRevision"] = json!(id(40));
        input["capturedAtUtcMs"] = json!(1.5);
        fail(&input, "invalid_time");
        input["capturedAtUtcMs"] = json!(utc("2026-10-30T10:00:00Z"));
        input["database"]["automationRules"][0]["actions"] = json!(
            (0..33)
                .map(|i| {
                    let mut a = set_action(4, json!(i));
                    a["id"] = json!(id(100 + i));
                    a
                })
                .collect::<Vec<_>>()
        );
        fail(&input, "action_limit");
        input = request(database());
        input["database"]["futureRoot"] = json!("a".repeat(8_000_001));
        fail(&input, "size_limit");
    }

    #[test]
    fn schedule_due_uses_iana_calendar_skips_dst_gaps_and_preserves_wall_clock() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("America/New_York", "2026-03-07", "02:30")]);
        let result = run(&due(db, "2026-03-10T23:00:00Z"));
        let times = result["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["event"]["scheduledForUtcMs"].as_i64().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            times,
            vec![
                utc("2026-03-07T07:30:00Z"),
                utc("2026-03-09T06:30:00Z"),
                utc("2026-03-10T06:30:00Z")
            ]
        );
        assert_eq!(result["hasMore"], false);
    }

    #[test]
    fn schedule_fold_earlier_or_later_emits_one_occurrence() {
        for (policy, expected) in [
            ("earlier", "2026-11-01T05:30:00Z"),
            ("later", "2026-11-01T06:30:00Z"),
        ] {
            let mut db = database();
            let mut r = scheduled_rule("America/New_York", "2026-11-01", "01:30");
            r["trigger"]["ambiguous"] = json!(policy);
            r["trigger"]["endDate"] = json!("2026-11-01");
            db["automationRules"] = json!([r]);
            let result = run(&due(db, "2026-11-02T00:00:00Z"));
            assert_eq!(result["events"].as_array().unwrap().len(), 1);
            assert_eq!(
                result["events"][0]["event"]["scheduledForUtcMs"],
                utc(expected)
            );
        }
    }

    #[test]
    fn monthly_interval_anchors_to_start_month_and_skips_missing_month_days() {
        let mut db = database();
        let mut r = scheduled_rule("Asia/Seoul", "2026-01-31", "09:00");
        r["trigger"]["frequency"] = json!("monthly");
        r["trigger"]["interval"] = json!(2);
        db["automationRules"] = json!([r]);
        let result = run(&due(db, "2026-06-01T00:00:00Z"));
        let times = result["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["event"]["scheduledForUtcMs"].as_i64().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            times,
            vec![
                utc("2026-01-31T00:00:00Z"),
                utc("2026-03-31T00:00:00Z"),
                utc("2026-05-31T00:00:00Z")
            ]
        );
    }

    #[test]
    fn yearly_interval_preserves_the_start_date_and_skips_non_leap_years() {
        let mut db = database();
        let mut r = scheduled_rule("Asia/Seoul", "2024-02-29", "09:00");
        r["trigger"]["frequency"] = json!("yearly");
        r["trigger"]["interval"] = json!(3);
        db["automationRules"] = json!([r]);
        let mut query = due(db, "2036-03-01T00:00:00Z");
        let first = run(&query);
        assert_eq!(first["hasMore"], true);
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(
            first["events"][0]["event"]["scheduledForUtcMs"],
            utc("2024-02-29T00:00:00Z")
        );
        query["cursor"] = first["cursor"].clone();
        let last = run(&query);
        assert_eq!(last["hasMore"], false);
        assert_eq!(last["events"].as_array().unwrap().len(), 1);
        assert_eq!(
            last["events"][0]["event"]["scheduledForUtcMs"],
            utc("2036-02-29T00:00:00Z")
        );
    }

    #[test]
    fn repeating_template_requires_materialization_support_and_keeps_slot_identity() {
        let mut db = database();
        let mut r = scheduled_rule("Asia/Seoul", "2026-10-30", "09:00");
        r["actions"] = json!([{"id":id(21),"type":"addRowFromTemplate","templateId":id(60),
            "values":{id(2):"Override"}}]);
        db["automationRules"] = json!([r]);
        db["pivRowTemplates"] = json!({"schemaVersion":1,"items":[{"id":id(60),"name":"Template",
            "values":{},"propertyTypes":{},"body":{"version":1,"blocks":[]}}]});
        let mut input = request(db.clone());
        input["event"] = run(&due(db, "2026-10-30T01:00:00Z"))["events"][0]["event"].clone();
        fail(&input, "template_materialization_required");

        input["materializeTemplates"] = json!(true);
        let first = run(&input);
        let effect = &first["receipts"][0]["actionResults"][0];
        assert_eq!(effect["type"], "addRow");
        assert_eq!(effect["templateId"], id(60));
        assert_eq!(effect["rowId"], first["database"]["rows"][1]["id"]);
        assert_eq!(
            first["database"]["rows"][1]["values"],
            json!({id(2):"Override"})
        );
        assert_eq!(run(&input)["receipts"], first["receipts"]);

        let mut snapshot = first["database"].clone();
        snapshot["rows"][1]["body"]["blocks"] = json!([{"id":id(65),"type":"paragraph"}]);
        assert_eq!(
            run(&json!({"mode":"validateSnapshot","deviceId":id(50),"database":snapshot})),
            json!({"valid":true})
        );
        input["database"] = snapshot;
        let retry = run(&input);
        assert_eq!(retry["duplicate"], true);
        assert_eq!(retry["receipts"], first["receipts"]);
        assert_eq!(retry["database"]["rows"].as_array().unwrap().len(), 2);
        assert_eq!(
            retry["database"]["rows"][1]["body"]["blocks"][0]["id"],
            id(65)
        );
    }

    #[test]
    fn repeating_template_validates_reference_and_needs_a_schedule() {
        let mut db = database();
        let mut r = scheduled_rule("UTC", "2026-10-30", "09:00");
        r["actions"] = json!([{"id":id(21),"type":"addRowFromTemplate","templateId":id(60),
            "values":{id(2):"Override"}}]);
        db["automationRules"] = json!([r]);
        let mut input = json!({"mode":"validate","database":db,"deviceId":id(50)});
        fail(&input, "missing_template");
        input["database"]["pivRowTemplates"] = json!({"schemaVersion":2,"items":[{"id":id(60)}]});
        fail(&input, "missing_template");
        input["database"]["pivRowTemplates"] = json!({"schemaVersion":1,"items":[{"id":id(60)}]});
        assert_eq!(run(&input), json!({"valid":true}));
        input["database"]["automationRules"][0]["actions"][0]["values"][id(4)] = json!("text");
        fail(&input, "invalid_value");
        input["database"]["automationRules"][0]["actions"][0]["values"] = json!({});
        input["database"]["automationRules"][0]["trigger"] = json!({"type":"manual"});
        fail(&input, "unsupported_action");
        input["database"]["automationRules"][0] = scheduled_rule("UTC", "2026-10-30", "09:00");
        input["database"]["automationRules"][0]["actions"] = json!([{"id":id(21),
            "type":"addRowFromTemplate","templateId":id(70),"values":{}}]);
        input["database"]["automationRules"][0]["enabled"] = json!(false);
        fail(&input, "missing_template");
        input["database"]["automationRules"][0]["archived"] = json!(true);
        assert_eq!(run(&input), json!({"valid":true}));
    }

    #[test]
    fn schedule_apply_derives_slot_identity_and_duplicate_ignores_caller_request_ids() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("Asia/Seoul", "2026-10-30", "09:00")]);
        let mut input = request(db);
        input["event"] =
            json!({"id":id(30),"type":"schedule","scheduledForUtcMs":utc("2026-10-30T00:00:00Z")});
        let first = run(&input);
        let mut retry = input;
        retry["database"] = first["database"].clone();
        retry["event"]["id"] = json!(id(31));
        let second = run(&retry);
        assert_eq!(second["duplicate"], true);
        assert_eq!(first["receipts"], second["receipts"]);
        assert_eq!(
            first["receipts"][0]["scheduledForUtcMs"],
            utc("2026-10-30T00:00:00Z")
        );
        assert_eq!(first["receipts"][0]["timeZone"], "Asia/Seoul");
        assert!(first["receipts"][0]["tzdbVersion"].is_string());
    }

    #[test]
    fn schedule_owner_timezone_invalid_slot_and_future_execution_are_validated() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("Asia/Seoul", "2026-10-30", "09:00")]);
        let mut input = request(db.clone());
        input["event"] = json!({"type":"schedule","scheduledForUtcMs":utc("2026-10-30T01:00:00Z")});
        fail(&input, "not_due");
        input["event"]["scheduledForUtcMs"] = json!(utc("2026-10-31T00:00:00Z"));
        fail(&input, "not_due");
        input["event"]["scheduledForUtcMs"] = json!(utc("2026-10-30T00:00:00Z"));
        input["deviceId"] = json!(id(51));
        fail(&input, "not_execution_owner");
        let mut query = due(db, "2026-10-31T10:00:00Z");
        query["deviceId"] = json!(id(51));
        assert_eq!(run(&query)["events"], json!([]));
        query["deviceId"] = json!(id(50));
        query["database"]["automationRules"][0]["trigger"]["timeZone"] = json!("Imaginary/Zone");
        fail(&query, "unsupported_timezone");
    }

    #[test]
    fn due_pages_are_bounded_bound_to_rule_snapshot_and_exclude_executed_slots() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("UTC", "2026-01-01", "00:00")]);
        let mut query = due(db, "2026-03-01T00:00:00Z");
        let first = run(&query);
        assert_eq!(first["events"].as_array().unwrap().len(), 32);
        assert_eq!(first["hasMore"], true);
        query["cursor"] = first["cursor"].clone();
        let second = run(&query);
        assert_eq!(second["events"].as_array().unwrap().len(), 28);
        assert_eq!(second["hasMore"], false);
        query["database"]["automationRules"][0]["version"] = json!(2);
        fail(&query, "stale_cursor");
        let mut execution = request(query["database"].clone());
        execution["event"] = first["events"][0]["event"].clone();
        let written = run(&execution);
        let result = run(&due(written["database"].clone(), "2026-01-01T00:00:00Z"));
        assert_eq!(result["events"], json!([]));
    }

    #[test]
    fn due_calendar_scan_has_a_cursor_budget_even_with_sparse_recurrences() {
        let mut db = database();
        let mut r = scheduled_rule("UTC", "1900-01-01", "00:00");
        r["trigger"]["frequency"] = json!("monthly");
        r["trigger"]["interval"] = json!(365);
        db["automationRules"] = json!([r]);
        let result = run(&due(db, "2026-10-30T10:00:00Z"));
        assert_eq!(result["hasMore"], true);
        assert!(result["cursor"].is_object());
        assert!(result["events"].as_array().unwrap().len() <= 32);
    }

    #[test]
    fn row_added_uses_row_identity_for_form_retry_and_accepts_form_origin() {
        let mut db = database();
        db["automationRules"][0]["trigger"] = json!({"type":"rowAdded"});
        let mut input = request(db);
        input.as_object_mut().unwrap().remove("ruleId");
        input["event"] = json!({"id":id(30),"type":"rowAdded","rowId":id(10),"origin":"form"});
        let first = run(&input);
        assert_eq!(first["database"]["rows"].as_array().unwrap().len(), 2);
        input["database"] = first["database"].clone();
        input["event"]["id"] = json!(id(31));
        let repeated = run(&input);
        assert_eq!(repeated["duplicate"], true);
        assert_eq!(repeated["receipts"], first["receipts"]);
    }

    #[test]
    fn validate_checks_every_rule_without_rows_or_receipts_and_preserves_source() {
        let db = database();
        let mut input = json!({"mode":"validate","database":db,"deviceId":id(50)});
        let before = input.clone();
        assert_eq!(run(&input), json!({"valid":true}));
        assert_eq!(input, before);
        input["database"]["automationRules"][0]["enabled"] = json!(false);
        input["database"]["automationRules"][0]["actions"] = json!([set_action(4, json!("bad"))]);
        fail(&input, "invalid_value");
    }

    #[test]
    fn validate_rejects_mistyped_schema_and_existing_basic_cells() {
        let mut input = json!({"mode":"validate","database":database(),"deviceId":id(50)});
        input["database"]["schemaVersion"] = json!("1");
        fail(&input, "unsupported_schema");
        input["database"]["schemaVersion"] = json!(1);
        input["database"]["rows"][0]["values"][id(4)] = json!("bad number");
        fail(&input, "invalid_value");
    }

    #[test]
    fn validate_rejects_mistyped_dst_policy_and_deleted_explicit_setter_targets() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("America/New_York", "2026-01-01", "09:00")]);
        let mut input = json!({"mode":"validate","database":db,"deviceId":id(50)});
        input["database"]["automationRules"][0]["trigger"]["ambiguous"] = json!(12);
        fail(&input, "invalid_schedule");
        input["database"]["automationRules"][0]["trigger"]["ambiguous"] = json!("earlier");
        let mut action = set_action(4, json!(1));
        action["rowId"] = json!(id(999));
        input["database"]["automationRules"][0]["actions"] = json!([action]);
        fail(&input, "missing_row");
        input["database"]["automationRules"][0]["actions"][0]
            .as_object_mut()
            .unwrap()
            .remove("rowId");
        fail(&input, "missing_row");
    }

    #[test]
    fn receipt_identity_and_count_are_checked_before_replay() {
        let result = run(&request(database()));
        let mut input = request(result["database"].clone());
        input["database"]["automationExecutions"][0]["id"] = json!(id(999));
        fail(&input, "invalid_receipt");
        let receipt = result["receipts"][0].clone();
        input["database"]["automationExecutions"] = json!(vec![receipt; 10_001]);
        fail(&input, "receipt_limit");
    }

    #[test]
    fn unicode_decimal_digits_in_iso_offset_are_rejected_without_panicking() {
        let mut input = request(database());
        input["database"]["properties"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":id(60),"name":"Date","type":"date","config":{}}));
        input["database"]["automationRules"][0]["actions"] =
            json!([set_action(60, json!("2026-10-30T09:00:00+١٢:٣٤"))]);
        let reduced = std::panic::catch_unwind(|| apply(input.as_object().unwrap()));
        assert!(
            reduced.is_ok(),
            "Untrusted date offsets must return a validation error"
        );
        fail(&input, "invalid_value");
    }

    #[test]
    fn schedule_condition_requires_live_fixed_row_and_due_carries_it() {
        let mut db = database();
        let mut r = scheduled_rule("UTC", "2026-10-30", "09:00");
        r["condition"] = json!({"propertyId":id(4),"operator":"eq","value":1});
        db["automationRules"] = json!([r]);
        let mut input = json!({"mode":"validate","database":db,"deviceId":id(50)});
        fail(&input, "missing_row");
        input["database"]["automationRules"][0]["trigger"]["rowId"] = json!(id(10));
        assert_eq!(run(&input), json!({"valid":true}));
        let result = run(&due(input["database"].clone(), "2026-10-30T10:00:00Z"));
        assert_eq!(result["events"][0]["event"]["rowId"], id(10));
        input["database"]["rows"][0]["archived"] = json!(true);
        fail(&input, "archived_row");
        input["database"]["rows"] = json!([]);
        fail(&input, "missing_row");
    }

    #[test]
    fn schedule_condition_uses_rule_row_instead_of_caller_row_and_replay_is_stable() {
        let mut db = database();
        let mut r = scheduled_rule("UTC", "2026-10-30", "09:00");
        r["trigger"]["rowId"] = json!(id(10));
        r["condition"] = json!({"propertyId":id(4),"operator":"eq","value":1});
        db["automationRules"] = json!([r]);
        let mut input = request(db);
        input["event"] = json!({"type":"schedule","scheduledForUtcMs":utc("2026-10-30T09:00:00Z"),"rowId":id(999)});
        let result = run(&input);
        assert_eq!(result["receipts"][0]["status"], "completed");
        assert_eq!(result["database"]["rows"].as_array().unwrap().len(), 2);
        input["database"] = result["database"].clone();
        input["database"]["automationRules"][0]["version"] = json!(2);
        let added = input["database"]["rows"][1]["id"].clone();
        input["database"]["automationRules"][0]["trigger"]["rowId"] = added;
        input["event"]["rowId"] = json!(id(998));
        let replay = run(&input);
        assert_eq!(replay["duplicate"], true);
        assert_eq!(replay["receipts"], result["receipts"]);
    }

    #[test]
    fn since_horizon_skips_old_calendar_scan_and_uses_exclusive_since_inclusive_cutoff() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("Asia/Seoul", "1900-01-01", "09:00")]);
        let mut query = due(db, "2026-10-31T00:00:00Z");
        query["sinceUtcMs"] = json!(utc("2026-10-30T00:00:00Z"));
        let result = run(&query);
        assert_eq!(result["hasMore"], false);
        assert_eq!(result["events"].as_array().unwrap().len(), 1);
        assert_eq!(
            result["events"][0]["event"]["scheduledForUtcMs"],
            utc("2026-10-31T00:00:00Z")
        );
        query["sinceUtcMs"] = json!(utc("2026-11-01T00:00:00Z"));
        fail(&query, "invalid_time");
    }

    #[test]
    fn since_preserves_weekly_monthly_anchors_and_later_fold_on_the_same_local_day() {
        for (frequency, interval, start, since, cutoff, expected) in [
            (
                "weekly",
                1,
                "2026-10-26",
                "2026-10-27T00:00:00Z",
                "2026-11-09T09:00:00Z",
                vec!["2026-11-02T09:00:00Z", "2026-11-09T09:00:00Z"],
            ),
            (
                "monthly",
                2,
                "2026-01-31",
                "2026-03-01T00:00:00Z",
                "2026-05-31T09:00:00Z",
                vec!["2026-03-31T09:00:00Z", "2026-05-31T09:00:00Z"],
            ),
        ] {
            let mut db = database();
            let mut r = scheduled_rule("UTC", start, "09:00");
            r["trigger"]["frequency"] = json!(frequency);
            r["trigger"]["interval"] = json!(interval);
            db["automationRules"] = json!([r]);
            let mut query = due(db, cutoff);
            query["sinceUtcMs"] = json!(utc(since));
            let result = run(&query);
            let slots = result["events"]
                .as_array()
                .unwrap()
                .iter()
                .map(|event| event["event"]["scheduledForUtcMs"].as_i64().unwrap())
                .collect::<Vec<_>>();
            assert_eq!(
                slots,
                expected.iter().map(|value| utc(value)).collect::<Vec<_>>()
            );
        }
        let mut db = database();
        let mut r = scheduled_rule("America/New_York", "2026-11-01", "01:30");
        r["trigger"]["ambiguous"] = json!("later");
        db["automationRules"] = json!([r]);
        let mut query = due(db, "2026-11-01T06:30:00Z");
        query["sinceUtcMs"] = json!(utc("2026-11-01T05:45:00Z"));
        let result = run(&query);
        assert_eq!(result["events"].as_array().unwrap().len(), 1);
        assert_eq!(
            result["events"][0]["event"]["scheduledForUtcMs"],
            utc("2026-11-01T06:30:00Z")
        );
    }

    #[test]
    fn due_cursor_cannot_be_reused_with_a_different_since_horizon() {
        let mut db = database();
        db["automationRules"] = json!([scheduled_rule("UTC", "2026-01-01", "00:00")]);
        let mut query = due(db, "2026-03-01T00:00:00Z");
        query["sinceUtcMs"] = json!(utc("2025-12-31T00:00:00Z"));
        let first = run(&query);
        assert_eq!(first["hasMore"], true);
        query["cursor"] = first["cursor"].clone();
        query["sinceUtcMs"] = json!(utc("2026-01-02T00:00:00Z"));
        fail(&query, "invalid_cursor");
    }
}
