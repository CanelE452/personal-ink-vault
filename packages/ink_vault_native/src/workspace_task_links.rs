use crate::{ApiResult, error, invalid, valid_id_str};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

const MAX_ROWS: usize = 10_000;
const MAX_PREDECESSORS: usize = 64;
const MAX_EDGES: usize = 20_000;

struct TaskLinks<'a> {
    parent: Option<&'a str>,
    predecessors: Vec<&'a str>,
}

impl TaskLinks<'_> {
    fn edge_count(&self) -> usize {
        usize::from(self.parent.is_some()) + self.predecessors.len()
    }
}

pub(crate) fn apply(request: &Map<String, Value>) -> ApiResult<Value> {
    if request.len() != 6 {
        return Err(invalid());
    }
    let rows = read_rows(request.get("rows"))?;
    let row_id = read_id(request.get("rowId"))?;
    if archived(&rows, row_id)? {
        return Err(archived_task());
    }
    let parent = match request.get("parentId").ok_or_else(invalid)? {
        Value::Null => None,
        value => Some(read_id(Some(value))?),
    };
    let predecessors = read_predecessors(request.get("predecessorIds").ok_or_else(invalid)?)?;
    let mut graph = read_graph(request.get("taskLinks").ok_or_else(invalid)?)?;
    graph.retain(|source, links| {
        // Older editors may remove rows without seeing the links stored for them.
        links.parent = links.parent.filter(|target| rows.contains_key(target));
        links
            .predecessors
            .retain(|target| rows.contains_key(target));
        rows.contains_key(source) && links.edge_count() != 0
    });
    let previous = graph.remove(row_id);
    if let Some(target) = parent {
        check_target(
            &rows,
            row_id,
            target,
            previous.as_ref().and_then(|links| links.parent) == parent,
        )?;
    }
    for &target in &predecessors {
        check_target(
            &rows,
            row_id,
            target,
            previous
                .as_ref()
                .is_some_and(|links| links.predecessors.contains(&target)),
        )?;
    }
    if parent.is_some() || !predecessors.is_empty() {
        graph.insert(
            row_id,
            TaskLinks {
                parent,
                predecessors,
            },
        );
    }
    if graph.values().map(TaskLinks::edge_count).sum::<usize>() > MAX_EDGES {
        return Err(link_limit());
    }
    require_acyclic(
        &graph,
        |links| links.parent.as_slice(),
        "Parent task links contain a cycle",
    )?;
    require_acyclic(
        &graph,
        |links| &links.predecessors,
        "Predecessor task links contain a cycle",
    )?;
    let items = graph
        .into_iter()
        .map(|(id, links)| {
            let mut item = Map::new();
            if let Some(parent) = links.parent {
                item.insert("parentId".to_owned(), json!(parent));
            }
            if !links.predecessors.is_empty() {
                item.insert("predecessorIds".to_owned(), json!(links.predecessors));
            }
            (id.to_owned(), Value::Object(item))
        })
        .collect::<Map<String, Value>>();
    Ok(json!({"taskLinks": {"schemaVersion": 1, "items": items}}))
}

fn read_rows(value: Option<&Value>) -> ApiResult<BTreeMap<&str, bool>> {
    let rows = value.and_then(Value::as_array).ok_or_else(invalid)?;
    if rows.len() > MAX_ROWS {
        return Err(link_limit());
    }
    let mut parsed = BTreeMap::new();
    for row in rows {
        let row = row
            .as_object()
            .filter(|row| row.len() == 2)
            .ok_or_else(invalid)?;
        let id = read_id(row.get("id"))?;
        let archived = row
            .get("archived")
            .and_then(Value::as_bool)
            .ok_or_else(invalid)?;
        if parsed.insert(id, archived).is_some() {
            return Err(invalid());
        }
    }
    Ok(parsed)
}

fn read_id(value: Option<&Value>) -> ApiResult<&str> {
    value
        .and_then(Value::as_str)
        .filter(|id| valid_id_str(id))
        .ok_or_else(invalid)
}

fn read_graph(value: &Value) -> ApiResult<BTreeMap<&str, TaskLinks<'_>>> {
    if value.is_null() {
        return Ok(BTreeMap::new());
    }
    let envelope = value
        .as_object()
        .filter(|object| {
            object.len() == 2 && object.get("schemaVersion").and_then(Value::as_u64) == Some(1)
        })
        .ok_or_else(|| {
            error(
                "unsupported_task_links",
                "Task links schema is not supported",
            )
        })?;
    let items = envelope
        .get("items")
        .and_then(Value::as_object)
        .ok_or_else(invalid)?;
    if items.len() > MAX_ROWS {
        return Err(link_limit());
    }
    let mut result = BTreeMap::new();
    let mut edge_count = 0;
    for (row_id, value) in items {
        if !valid_id_str(row_id) {
            return Err(invalid());
        }
        let item = value
            .as_object()
            .filter(|item| {
                item.keys()
                    .all(|key| matches!(key.as_str(), "parentId" | "predecessorIds"))
            })
            .ok_or_else(invalid)?;
        let parent = item
            .get("parentId")
            .map(|value| read_id(Some(value)))
            .transpose()?;
        let predecessors = item
            .get("predecessorIds")
            .map(read_predecessors)
            .transpose()?
            .unwrap_or_default();
        let links = TaskLinks {
            parent,
            predecessors,
        };
        edge_count += links.edge_count();
        if edge_count > MAX_EDGES {
            return Err(link_limit());
        }
        result.insert(row_id.as_str(), links);
    }
    Ok(result)
}

fn read_predecessors(value: &Value) -> ApiResult<Vec<&str>> {
    let predecessors = value.as_array().ok_or_else(invalid)?;
    if predecessors.len() > MAX_PREDECESSORS {
        return Err(link_limit());
    }
    let mut seen = BTreeSet::new();
    let mut parsed = Vec::with_capacity(predecessors.len());
    for predecessor in predecessors {
        let id = read_id(Some(predecessor))?;
        if !seen.insert(id) {
            return Err(error(
                "duplicate_task_link",
                "A predecessor appears more than once",
            ));
        }
        parsed.push(id);
    }
    Ok(parsed)
}

fn check_target(
    rows: &BTreeMap<&str, bool>,
    row_id: &str,
    target: &str,
    existed: bool,
) -> ApiResult<()> {
    if row_id == target {
        return Err(error("self_task_link", "A task cannot link to itself"));
    }
    if archived(rows, target)? && !existed {
        return Err(archived_task());
    }
    Ok(())
}

fn archived(rows: &BTreeMap<&str, bool>, id: &str) -> ApiResult<bool> {
    rows.get(id)
        .copied()
        .ok_or_else(|| error("missing_task", "The task is not in this database"))
}

fn archived_task() -> crate::ApiError {
    error("archived_task", "New task links require active tasks")
}

fn link_limit() -> crate::ApiError {
    error("task_links_limit", "Task links exceed the supported size")
}

fn require_acyclic<'a>(
    graph: &BTreeMap<&'a str, TaskLinks<'a>>,
    edges: impl for<'link> Fn(&'link TaskLinks<'a>) -> &'link [&'a str],
    message: &'static str,
) -> ApiResult<()> {
    let mut incoming = BTreeMap::new();
    for (&source, links) in graph {
        incoming.entry(source).or_insert(0usize);
        for &target in edges(links) {
            *incoming.entry(target).or_insert(0) += 1;
        }
    }
    let mut pending: Vec<&str> = incoming
        .iter()
        .filter_map(|(&id, &count)| (count == 0).then_some(id))
        .collect();
    let mut visited = 0;
    while let Some(id) = pending.pop() {
        visited += 1;
        if let Some(links) = graph.get(id) {
            for target in edges(links) {
                let count = incoming.get_mut(target).ok_or_else(invalid)?;
                *count -= 1;
                if *count == 0 {
                    pending.push(target);
                }
            }
        }
    }
    if visited != incoming.len() {
        return Err(error("task_link_cycle", message));
    }
    Ok(())
}
