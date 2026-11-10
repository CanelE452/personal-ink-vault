use std::cell::OnceCell;
use std::collections::BTreeSet;
use std::iter::Peekable;
use std::ops::Range;
use std::vec::IntoIter;

use serde_json::{Map, Value, json};

use super::{ApiError, ApiResult, body_match_json, error, invalid, normalize, string};

const MAX_QUERY_UNITS: usize = 2048;
const MAX_TOKENS: usize = 256;
const MAX_DEPTH: usize = 32;

fn invalid_expression() -> ApiError {
    error(
        "invalid_search_expression",
        "Invalid or unsupported search expression",
    )
}

#[derive(PartialEq)]
enum Token<'a> {
    Word(&'a str),
    Quoted(String),
    Open,
    Close,
    Colon,
    Minus,
    Or,
}

fn tokenize(query: &str) -> ApiResult<Vec<Token<'_>>> {
    if query.encode_utf16().take(MAX_QUERY_UNITS + 1).count() > MAX_QUERY_UNITS
        || query
            .chars()
            .any(|ch| ch.is_control() && !ch.is_whitespace())
    {
        return Err(invalid_expression());
    }
    let mut tokens = Vec::new();
    let mut chars = query.char_indices().peekable();
    while let Some((start, ch)) = chars.next() {
        let token = match ch {
            ch if ch.is_whitespace() => continue,
            '(' => Token::Open,
            ')' => Token::Close,
            ':' => Token::Colon,
            '-' => Token::Minus,
            '[' | ']' | '<' | '>' | '/' => return Err(invalid_expression()),
            '"' => {
                let mut text = String::new();
                loop {
                    match chars.next().map(|(_, ch)| ch) {
                        Some('"') => break,
                        Some('\\') => text.push(chars.next().ok_or_else(invalid_expression)?.1),
                        Some(ch) => text.push(ch),
                        None => return Err(invalid_expression()),
                    }
                }
                if text.is_empty() {
                    return Err(invalid_expression());
                }
                Token::Quoted(text)
            }
            _ => {
                while chars
                    .next_if(|(_, ch)| {
                        !ch.is_whitespace()
                            && !matches!(ch, '(' | ')' | ':' | '"' | '[' | ']' | '<' | '>')
                    })
                    .is_some()
                {}
                let end = chars.peek().map_or(query.len(), |(index, _)| *index);
                match &query[start..end] {
                    "OR" => Token::Or,
                    "TRUE" | "FALSE" | "EMPTY" => return Err(invalid_expression()),
                    word => Token::Word(word),
                }
            }
        };
        tokens.push(token);
        if tokens.len() > MAX_TOKENS {
            return Err(invalid_expression());
        }
    }
    Ok(tokens)
}

#[derive(Clone, Copy)]
enum Field {
    Any,
    File,
    Path,
    Content,
}

enum Expression {
    Text { text: String, quoted: bool },
    Tag(String),
    Scoped(Field, Box<Expression>),
    Not(Box<Expression>),
    All(Vec<Expression>),
    Any(Vec<Expression>),
}

struct Parser<'a> {
    tokens: Peekable<IntoIter<Token<'a>>>,
}

impl Parser<'_> {
    fn or(&mut self, scoped: bool, depth: usize) -> ApiResult<Expression> {
        let first = self.and(scoped, depth)?;
        if self.tokens.peek() != Some(&Token::Or) {
            return Ok(first);
        }
        let mut alternatives = vec![first];
        while self.tokens.next_if_eq(&Token::Or).is_some() {
            alternatives.push(self.and(scoped, depth)?);
        }
        Ok(Expression::Any(alternatives))
    }

    fn and(&mut self, scoped: bool, depth: usize) -> ApiResult<Expression> {
        let first = self.atom(scoped, depth)?;
        if matches!(self.tokens.peek(), None | Some(Token::Or | Token::Close)) {
            return Ok(first);
        }
        let mut conditions = vec![first];
        while !matches!(self.tokens.peek(), None | Some(Token::Or | Token::Close)) {
            conditions.push(self.atom(scoped, depth)?);
        }
        Ok(Expression::All(conditions))
    }

    fn atom(&mut self, scoped: bool, depth: usize) -> ApiResult<Expression> {
        if depth > MAX_DEPTH {
            return Err(invalid_expression());
        }
        match self.tokens.next() {
            Some(Token::Minus) => Ok(Expression::Not(Box::new(self.atom(scoped, depth + 1)?))),
            Some(Token::Open) => {
                let group = self.or(scoped, depth + 1)?;
                self.tokens
                    .next_if_eq(&Token::Close)
                    .ok_or_else(invalid_expression)?;
                Ok(group)
            }
            Some(Token::Word(word)) if self.tokens.next_if_eq(&Token::Colon).is_some() => {
                if scoped {
                    return Err(invalid_expression());
                }
                let scope = match word.to_ascii_lowercase().as_str() {
                    "file" => Field::File,
                    "path" => Field::Path,
                    "content" => Field::Content,
                    "tag" => {
                        let Some(Token::Word(tag)) = self.tokens.next() else {
                            return Err(invalid_expression());
                        };
                        let tag = without_hash(tag);
                        if tag.split('/').any(str::is_empty) {
                            return Err(invalid_expression());
                        }
                        return Ok(Expression::Tag(normalize(tag)));
                    }
                    _ => return Err(invalid_expression()),
                };
                Ok(Expression::Scoped(
                    scope,
                    Box::new(self.atom(true, depth + 1)?),
                ))
            }
            Some(Token::Word(word)) => Ok(Expression::Text {
                text: normalize(word),
                quoted: false,
            }),
            Some(Token::Quoted(phrase)) => Ok(Expression::Text {
                text: normalize(&phrase),
                quoted: true,
            }),
            _ => Err(invalid_expression()),
        }
    }
}

fn parse(query: &str) -> ApiResult<Option<Expression>> {
    let tokens = tokenize(query)?;
    if tokens.is_empty() {
        return Ok(None);
    }
    let mut parser = Parser {
        tokens: tokens.into_iter().peekable(),
    };
    let expression = parser.or(false, 0)?;
    if parser.tokens.next().is_some() {
        return Err(invalid_expression());
    }
    Ok(Some(expression))
}

fn without_hash(tag: &str) -> &str {
    tag.strip_prefix('#').unwrap_or(tag)
}

struct Document<'a> {
    title: String,
    file: String,
    path: String,
    tags: Vec<String>,
    markdown: &'a str,
    body: OnceCell<String>,
}

impl Document<'_> {
    fn body(&self) -> &str {
        self.body.get_or_init(|| normalize(self.markdown))
    }

    fn snippet(&self, hit: Option<usize>) -> String {
        let (source, position) = match hit {
            Some(hit) => {
                let body = self.body();
                let position = body[..hit].chars().count();
                let source = if self.markdown.chars().count() == body.chars().count() {
                    self.markdown
                } else {
                    body
                };
                (source, position)
            }
            None => (self.markdown, 0),
        };
        let start = position.saturating_sub(40);
        let mut chars = source.chars().skip(start);
        let mut snippet: String = chars.by_ref().take(180).collect();
        if start > 0 {
            snippet.insert(0, '…');
        }
        if chars.next().is_some() {
            snippet.push('…');
        }
        snippet
    }
}

#[derive(Default)]
struct Match {
    score: u64,
    body_hit: Option<Range<usize>>,
}

fn earliest(a: Option<Range<usize>>, b: Option<Range<usize>>) -> Option<Range<usize>> {
    a.into_iter()
        .chain(b)
        .min_by_key(|range| (range.start, range.end))
}

impl Expression {
    fn evaluate(&self, doc: &Document<'_>, field: Field) -> Option<Match> {
        match self {
            Self::Text { text, quoted } => {
                let body_hit = match field {
                    Field::Any | Field::Content => body_match(doc.body(), text, *quoted),
                    _ => None,
                };
                let score = match field {
                    Field::Any if doc.title.contains(text) || doc.file.contains(text) => 10,
                    Field::File if doc.file.contains(text) => 10,
                    Field::Path if doc.path.contains(text) => 2,
                    Field::Any | Field::Content if body_hit.is_some() => 1,
                    _ => return None,
                };
                Some(Match { score, body_hit })
            }
            Self::Tag(tag) => doc
                .tags
                .iter()
                .any(|candidate| {
                    candidate == tag
                        || candidate
                            .strip_prefix(tag)
                            .is_some_and(|tail| tail.starts_with('/'))
                })
                .then_some(Match {
                    score: 1,
                    body_hit: None,
                }),
            Self::Scoped(Field::File, _) if doc.file.is_empty() => None,
            Self::Scoped(Field::Path, _) if doc.path.is_empty() => None,
            Self::Scoped(scope, condition) => condition.evaluate(doc, *scope),
            Self::Not(condition) => condition
                .evaluate(doc, field)
                .is_none()
                .then(Match::default),
            Self::All(conditions) => {
                conditions
                    .iter()
                    .try_fold(Match::default(), |total, condition| {
                        let matched = condition.evaluate(doc, field)?;
                        Some(Match {
                            score: total.score + matched.score,
                            body_hit: earliest(total.body_hit, matched.body_hit),
                        })
                    })
            }
            Self::Any(alternatives) => alternatives
                .iter()
                .filter_map(|condition| condition.evaluate(doc, field))
                .reduce(|a, b| Match {
                    score: a.score.max(b.score),
                    body_hit: earliest(a.body_hit, b.body_hit),
                }),
        }
    }
}

fn body_match(body: &str, text: &str, quoted: bool) -> Option<Range<usize>> {
    if !quoted {
        return body.find(text).map(|start| start..start + text.len());
    }
    let first = text.chars().next()?;
    let left_edge = phrase_word_char(first);
    let right_edge = text.chars().next_back().is_some_and(phrase_word_char);
    let mut start = 0;
    while let Some(relative) = body[start..].find(text) {
        start += relative;
        let end = start + text.len();
        let valid_left = !left_edge
            || !body[..start]
                .chars()
                .next_back()
                .is_some_and(phrase_word_char);
        let valid_right = !right_edge || !body[end..].chars().next().is_some_and(phrase_word_char);
        if valid_left && valid_right {
            return Some(start..end);
        }
        start += first.len_utf8();
    }
    None
}

fn phrase_word_char(ch: char) -> bool {
    // In continuous East Asian text, a phrase need not have spaces around it.
    ch.len_utf16() == 1
        && (ch.is_alphabetic() || ch.is_numeric())
        && !matches!(ch,
        '\u{3040}'..='\u{30ff}' | '\u{31f0}'..='\u{31ff}' | '\u{3400}'..='\u{9fff}'
        | '\u{ac00}'..='\u{d7a3}' | '\u{f900}'..='\u{faff}' | '\u{ff66}'..='\u{ff9f}')
}

pub(super) fn validate(request: &Map<String, Value>) -> ApiResult<Value> {
    parse(string(request.get("query"))?)?;
    Ok(json!({"valid": true}))
}

fn optional_text(value: Option<&Value>) -> ApiResult<&str> {
    match value {
        None | Some(Value::Null) => Ok(""),
        Some(value) => string(Some(value)),
    }
}

pub(super) fn search(request: &Map<String, Value>) -> ApiResult<Value> {
    let expression = parse(string(request.get("query"))?)?;
    let include_body_match = request.get("includeBodyMatch").and_then(Value::as_bool) == Some(true);
    let documents = request
        .get("documents")
        .and_then(Value::as_array)
        .ok_or_else(invalid)?;
    let mut ids = BTreeSet::new();
    let mut matches = Vec::new();
    for document in documents {
        let id = string(document.get("id"))?;
        if id.is_empty() || !ids.insert(id) {
            return Err(invalid());
        }
        let title = string(document.get("title"))?;
        let markdown = string(document.get("markdown"))?;
        let file = optional_text(document.get("file"))?;
        let path = optional_text(document.get("path"))?;
        let tags = match document.get("tags") {
            None | Some(Value::Null) => &[][..],
            Some(value) => value.as_array().ok_or_else(invalid)?.as_slice(),
        };
        let tags = tags
            .iter()
            .map(|tag| Ok(normalize(without_hash(string(Some(tag))?))))
            .collect::<ApiResult<Vec<_>>>()?;
        let Some(expression) = &expression else {
            continue;
        };
        let doc = Document {
            title: normalize(title),
            file: normalize(file),
            path: normalize(path),
            tags,
            markdown,
            body: OnceCell::new(),
        };
        if let Some(matched) = expression.evaluate(&doc, Field::Any) {
            let snippet = doc.snippet(matched.body_hit.as_ref().map(|range| range.start));
            let body_match = if include_body_match {
                matched
                    .body_hit
                    .and_then(|hit| body_match_json(markdown, doc.body(), hit))
            } else {
                None
            };
            matches.push((matched.score, doc.title, id, title, snippet, body_match));
        }
    }
    matches.sort_unstable_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.2.cmp(b.2))
    });
    let matches: Vec<Value> = matches
        .into_iter()
        .map(|(score, _, id, title, snippet, body_match)| {
            let mut result = json!({"id": id, "title": title, "snippet": snippet, "score": score});
            if let Some(position) = body_match {
                result["bodyMatch"] = position;
            }
            result
        })
        .collect();
    Ok(json!({"matches": matches}))
}
