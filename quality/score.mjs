#!/usr/bin/env node

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  const key = process.argv[index];
  const value = process.argv[index + 1];
  if (!key?.startsWith('--') || value == null) throw new Error('usage: score.mjs --manifest FILE --candidate FILE --baseline FILE [--best-single FILE] [--out FILE]');
  args.set(key.slice(2), value);
}
for (const required of ['manifest', 'candidate', 'baseline']) {
  if (!args.has(required)) throw new Error(`missing --${required}`);
}
const load = key => JSON.parse(readFileSync(resolve(args.get(key)), 'utf8'));
const manifest = load('manifest');
const candidate = load('candidate');
const baseline = load('baseline');
const bestSingle = args.has('best-single') ? load('best-single') : null;
const registry = JSON.parse(readFileSync(resolve(root, 'models/registry.json'), 'utf8'));

const normalize = text => text
  .normalize('NFKC')
  .toLocaleLowerCase('en-US')
  .replace(/[’']/gu, '')
  .replace(/[^\p{L}\p{N}]+/gu, ' ')
  .trim()
  .split(/\s+/u)
  .filter(Boolean);

function distance(reference, hypothesis) {
  const previous = Array.from({ length: hypothesis.length + 1 }, (_, index) => index);
  for (let row = 1; row <= reference.length; row++) {
    const current = [row];
    for (let column = 1; column <= hypothesis.length; column++) {
      current[column] = Math.min(
        previous[column] + 1,
        current[column - 1] + 1,
        previous[column - 1] + (reference[row - 1] === hypothesis[column - 1] ? 0 : 1),
      );
    }
    previous.splice(0, previous.length, ...current);
  }
  return previous[hypothesis.length];
}

const itemMap = run => new Map(run.items.map(item => [item.id, item]));
const round = value => Number(value.toFixed(6));
const relativeImprovement = (before, after) => before === 0 ? (after === 0 ? 0 : -Infinity) : (before - after) / before;

function measure(run) {
  const hypotheses = itemMap(run);
  let referenceWords = 0;
  let errors = 0;
  let technicalExpected = 0;
  let technicalErrors = 0;
  let contextApplied = 0;
  let contextCorrect = 0;
  let hallucinatedWords = 0;
  let silenceSeconds = 0;
  let durationSeconds = 0;
  let processingMs = 0;
  let preferred = 0;
  let preferenceVotes = 0;
  const categories = new Map();

  for (const item of manifest.items) {
    const hypothesis = hypotheses.get(item.id);
    if (!hypothesis) throw new Error(`${run.platform}/${run.quality_mode} is missing ${item.id}`);
    const reference = normalize(item.reference);
    const actual = normalize(hypothesis.text);
    const itemErrors = distance(reference, actual);
    referenceWords += reference.length;
    errors += itemErrors;
    durationSeconds += item.duration_seconds;
    processingMs += hypothesis.processing_ms;
    for (const category of item.categories) {
      const aggregate = categories.get(category) ?? { errors: 0, words: 0 };
      aggregate.errors += itemErrors;
      aggregate.words += reference.length;
      categories.set(category, aggregate);
    }
    for (const term of item.technical_terms ?? []) {
      const normalizedTerm = normalize(term).join(' ');
      if (!normalizedTerm || !normalize(item.reference).join(' ').includes(normalizedTerm)) continue;
      technicalExpected++;
      if (!actual.join(' ').includes(normalizedTerm)) technicalErrors++;
    }
    for (const term of hypothesis.applied_vocabulary ?? []) {
      contextApplied++;
      if (normalize(item.reference).join(' ').includes(normalize(term).join(' '))) contextCorrect++;
    }
    const itemSilence = item.silence_seconds ?? (reference.length === 0 ? item.duration_seconds : 0);
    if (itemSilence > 0) {
      silenceSeconds += itemSilence;
      hallucinatedWords += actual.length;
    }
    if (item.readability_preference && item.readability_preference !== 'unscored') {
      preferenceVotes++;
      if (item.readability_preference === 'candidate') preferred++;
      if (item.readability_preference === 'tie') preferred += 0.5;
    }
  }

  return {
    wer: round(errors / Math.max(1, referenceWords)),
    errors,
    reference_words: referenceWords,
    technical_term_error_rate: round(technicalErrors / Math.max(1, technicalExpected)),
    technical_term_errors: technicalErrors,
    context_precision: round(contextCorrect / Math.max(1, contextApplied)),
    context_applied: contextApplied,
    hallucinated_words_per_silence_minute: round(hallucinatedWords / Math.max(1, silenceSeconds / 60)),
    processing_minutes_per_recorded_hour: round((processingMs / 60000) / Math.max(1 / 60, durationSeconds / 3600)),
    readability_preference: round(preferred / Math.max(1, preferenceVotes)),
    recorded_hours: round(durationSeconds / 3600),
    category_wer: Object.fromEntries([...categories].sort().map(([name, value]) => [name, round(value.errors / Math.max(1, value.words))])),
  };
}

function modelBytes(run) {
  const byId = new Map(registry.models.map(model => [model.id, model]));
  return run.models.reduce((sum, id) => {
    const model = byId.get(id);
    if (!model) throw new Error(`run references unknown model ${id}`);
    if (!model.platforms.includes(run.platform)) throw new Error(`${id} is not registered for ${run.platform}`);
    return sum + model.download_bytes;
  }, 0);
}

const metrics = measure(candidate);
const baselineMetrics = measure(baseline);
const bestSingleMetrics = bestSingle ? measure(bestSingle) : null;
metrics.model_download_bytes = modelBytes(candidate);
metrics.relative_wer_improvement = round(relativeImprovement(baselineMetrics.wer, metrics.wer));
metrics.technical_term_error_reduction = round(relativeImprovement(
  baselineMetrics.technical_term_error_rate,
  metrics.technical_term_error_rate,
));
const categoryRegression = Object.keys(baselineMetrics.category_wer).some(category =>
  (metrics.category_wer[category] ?? 0) - baselineMetrics.category_wer[category] > 0.01);
const processingBudget = candidate.quality_mode === 'standard' ? 2 : 5;
const storageBudget = candidate.quality_mode === 'standard' ? 1_500_000_000 : 3_000_000_000;
const gates = {
  private_corpus_at_least_three_hours: manifest.private === true && metrics.recorded_hours >= 3,
  relative_wer_improvement_at_least_15_percent: metrics.relative_wer_improvement >= 0.15,
  technical_term_error_reduction_at_least_25_percent: metrics.technical_term_error_reduction >= 0.25,
  context_precision_at_least_90_percent: metrics.context_applied > 0 && metrics.context_precision >= 0.9,
  no_major_category_regression_over_one_point: !categoryRegression,
  hallucination_at_most_point_one_words_per_silence_minute: metrics.hallucinated_words_per_silence_minute <= 0.1,
  readability_preference_at_least_70_percent: metrics.readability_preference >= 0.7,
  storage_budget: metrics.model_download_bytes <= storageBudget,
  processing_budget: metrics.processing_minutes_per_recorded_hour <= processingBudget,
};
if (candidate.quality_mode === 'max_accuracy' && candidate.models.length > 1) {
  if (!bestSingleMetrics) throw new Error('dual-engine Max Accuracy requires --best-single');
  const consensusRegression = Object.keys(bestSingleMetrics.category_wer).some(category =>
    (metrics.category_wer[category] ?? 0) > bestSingleMetrics.category_wer[category]);
  gates.consensus_improves_best_single_wer_at_least_10_percent =
    relativeImprovement(bestSingleMetrics.wer, metrics.wer) >= 0.1;
  gates.consensus_has_no_category_regression = !consensusRegression;
}

const output = {
  score_version: 1,
  corpus: manifest.name,
  platform: candidate.platform,
  quality_mode: candidate.quality_mode,
  metrics,
  baseline: baselineMetrics,
  best_single: bestSingleMetrics,
  gates,
  qualifies: Object.values(gates).every(Boolean),
};
const encoded = JSON.stringify(output, null, 2) + '\n';
if (args.has('out')) writeFileSync(resolve(args.get('out')), encoded);
else process.stdout.write(encoded);
