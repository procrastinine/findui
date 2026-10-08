use regex::{Regex, RegexBuilder};
use std::collections::VecDeque;

pub struct Proximity {
    terms: Vec<Regex>,
    words: Regex,
    window: usize,
    ordered: bool,
}
#[derive(Default)]
pub struct State {
    position: usize,
    recent: VecDeque<(usize, Vec<usize>)>,
    prefixes: Vec<Option<usize>>,
    pub ranges: Vec<(usize, usize)>,
}
impl Proximity {
    pub fn new(
        terms: &[String],
        distance: usize,
        ordered: bool,
        sensitive: bool,
    ) -> Result<Self, String> {
        let word = Regex::new(r"\A\w+\z").unwrap();
        if !(2..=16).contains(&terms.len())
            || distance > 1000
            || terms.iter().any(|t| !word.is_match(t))
        {
            return Err(
                "Proximity needs 2–16 individual words and 0–1000 intervening words".into(),
            );
        }
        let terms = terms
            .iter()
            .map(|t| {
                RegexBuilder::new(&format!("\\A{}\\z", regex::escape(t)))
                    .case_insensitive(!sensitive)
                    .build()
                    .map_err(|e| e.to_string())
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Self {
            window: distance + terms.len(),
            terms,
            words: Regex::new(r"\w+").unwrap(),
            ordered,
        })
    }
    pub fn matches(&self, bytes: &[u8], state: &mut State) -> bool {
        let text = String::from_utf8_lossy(bytes);
        let mut found = false;
        state.ranges.clear();
        if state.prefixes.is_empty() {
            state.prefixes.resize(self.terms.len(), None);
        }
        for word in self.words.find_iter(&text) {
            state.position += 1;
            let ids: Vec<_> = self
                .terms
                .iter()
                .enumerate()
                .filter_map(|(i, t)| t.is_match(word.as_str()).then_some(i))
                .collect();
            if !ids.is_empty() {
                state.ranges.push((word.start(), word.end()));
            }
            if self.ordered {
                for i in ids.into_iter().rev() {
                    if i == 0 {
                        state.prefixes[0] = Some(state.position);
                    } else if let Some(start) = state.prefixes[i - 1] {
                        if state.position - start < self.window {
                            state.prefixes[i] = Some(start);
                        }
                    }
                    if i + 1 == self.terms.len()
                        && state.prefixes[i].is_some_and(|p| state.position - p < self.window)
                    {
                        found = true;
                    }
                }
            } else {
                while state
                    .recent
                    .front()
                    .is_some_and(|(p, _)| state.position - *p >= self.window)
                {
                    state.recent.pop_front();
                }
                if ids.is_empty() {
                    continue;
                }
                state.recent.push_back((state.position, ids));
                if state.recent.len() < self.terms.len() {
                    continue;
                }
                // Distinct occurrences are required for repeated terms. A
                // bipartite assignment also handles equivalent Unicode folds.
                fn assign(
                    term: usize,
                    words: &VecDeque<(usize, Vec<usize>)>,
                    used: &mut [bool],
                    owners: &mut [Option<usize>],
                ) -> bool {
                    for i in 0..words.len() {
                        if !used[i] && words[i].1.contains(&term) {
                            used[i] = true;
                            if owners[i].is_none()
                                || assign(owners[i].unwrap(), words, used, owners)
                            {
                                owners[i] = Some(term);
                                return true;
                            }
                        }
                    }
                    false
                }
                let mut owners = vec![None; state.recent.len()];
                found |= (0..self.terms.len()).all(|term| {
                    assign(
                        term,
                        &state.recent,
                        &mut vec![false; state.recent.len()],
                        &mut owners,
                    )
                });
            }
        }
        found
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cross_line_order_distance_and_repeated_terms() {
        let near = Proximity::new(&["alpha".into(), "beta".into()], 1, false, false).unwrap();
        let mut s = State::default();
        assert!(!near.matches(b"beta one\n", &mut s));
        assert!(near.matches(b"alpha\n", &mut s));
        let near = Proximity::new(&["alpha".into(), "beta".into()], 0, true, false).unwrap();
        assert!(!near.matches(b"beta alpha", &mut State::default()));
        assert!(near.matches(b"alpha beta", &mut State::default()));
        let repeated = Proximity::new(&["a".into(), "a".into()], 0, false, false).unwrap();
        assert!(!repeated.matches(b"a", &mut State::default()));
        assert!(repeated.matches(b"a a", &mut State::default()));
    }
}
