/**
 * Retrieval for MCP brain_ask. Natural-language questions are reduced to a
 * bounded set of terms and searched only through the configured Brain Agent's
 * live external data root. Retrieval only — synthesis is the calling model's
 * job.
 */

import { searchAgentKnowledge, type RemoteApiEnv } from "./remote-api";

export const MAX_TERMS = 3;
export const MAX_HITS = 5;

/** One live Agent search match inside the canonical data root. */
export interface AskHit {
  path: string;
  title: string;
  fragment: string;
}

export type AskResult =
  | { ok: true; terms: string[]; hits: AskHit[] }
  | { ok: false; error: string };

/** Question words that carry no search signal. */
const STOPWORDS = new Set([
  "a", "about", "all", "am", "an", "and", "any", "anything", "are", "at", "be",
  "been", "but", "by", "can", "could", "did", "do", "does", "for", "from",
  "get", "had", "has", "have", "how", "i", "if", "in", "into", "is", "it",
  "its", "just", "know", "like", "me", "my", "no", "not", "of", "on", "or",
  "our", "should", "so", "some", "tell", "that", "the", "their", "them",
  "then", "there", "these", "they", "this", "to", "up", "us", "was", "we",
  "were", "what", "when", "where", "which", "who", "why", "will", "with",
  "would", "you", "your",
]);

/**
 * Up to `MAX_TERMS` content words from the question, in order, deduplicated.
 * Falls back to the raw words when everything is a stopword (so a terse
 * question like "what is it about" still searches for something).
 */
export function extractSearchTerms(question: string): string[] {
  const words = question
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, " ")
    .split(/\s+/)
    .filter(Boolean);

  const pick = (candidates: string[]): string[] => {
    const terms: string[] = [];
    for (const word of candidates) {
      if (!terms.includes(word)) terms.push(word);
      if (terms.length === MAX_TERMS) break;
    }
    return terms;
  };

  const content = pick(words.filter((word) => word.length > 1 && !STOPWORDS.has(word)));
  return content.length > 0 ? content : pick(words);
}

/** Live paired-Agent search over the external data root; top `MAX_HITS` results. */
export async function searchVault(env: RemoteApiEnv, question: string): Promise<AskResult> {
  const terms = extractSearchTerms(question);
  if (terms.length === 0) {
    return { ok: false, error: "question contains no searchable words" };
  }

  const hits: AskHit[] = [];
  const seen = new Set<string>();
  for (const term of terms) {
    const result = await searchAgentKnowledge(env, term, MAX_HITS);
    if (!result.ok) return result;
    for (const item of result.results) {
      if (!seen.add(item.path)) continue;
      hits.push({ path: item.path, title: item.title, fragment: item.snippet });
      if (hits.length === MAX_HITS) return { ok: true, terms, hits };
    }
  }
  return { ok: true, terms, hits };
}
