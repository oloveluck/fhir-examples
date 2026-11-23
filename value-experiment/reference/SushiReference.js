// SushiReference.js — the bridge to SUSHI, HL7's FSH compiler (value-experiment/PROTOCOL.md, H part 3).
//
//   NODE_PATH=<dir with fsh-sushi>/node_modules node SushiReference.js PAIRS.jsonl ANSWERS.jsonl [check N]
//
// PAIRS.jsonl holds one JSON object a line: {"id": "...", "file": "<an FSH text>"}. For each, in
// order, one line is written: {"id", "fhir": [<the resources SUSHI exports>], "errors": [<messages>],
// "warnings": <how many>}, or {"id", "crash": "<the exception's message>"}.
//
// What runs is what SUSHI's own sushiClient.fshToFhir runs, with its own functions and in its
// order — the text into the tank, the duplicate-name check, the exporter over the external
// definitions — with those definitions loaded once instead of for every text. FHIR 4.0.1,
// canonical http://example.org, version 1.0.0, FSHOnly (the client's setting), no dependencies.
// With `check N`, N texts spread over the list are afterwards given to sushiClient.fshToFhir
// itself and the two outputs compared as JSON text: the count that differ is printed (and is
// the program's exit status when it is not 0). This program calls and prints; it decides nothing
// about a pair.

const fs = require('fs');
const { sushiClient } = require('fsh-sushi');
const { RawFSH } = require('fsh-sushi/dist/import');
const { exportFHIR } = require('fsh-sushi/dist/export');
const { createFHIRDefinitions } = require('fsh-sushi/dist/fhirdefs');
const utils = require('fsh-sushi/dist/utils');

const kinds = ['profiles', 'extensions', 'instances', 'valueSets', 'codeSystems', 'logicals', 'resources'];
const settings = { canonical: 'http://example.org', version: '1.0.0', fhirVersion: '4.0.1' };

function compileOnce(text, defs) {
  utils.errorsAndWarnings.reset();
  utils.errorsAndWarnings.shouldTrack = true;
  const config = { canonical: settings.canonical, FSHOnly: true, fhirVersion: [settings.fhirVersion], dependencies: undefined, version: settings.version };
  const tank = utils.fillTank([new RawFSH(text)], config);
  tank.checkDuplicateNameEntities();
  const out = exportFHIR(tank, defs);
  const fhir = [];
  kinds.forEach(k => out[k].forEach(a => fhir.push(a.toJSON(false))));
  return { fhir, errors: utils.errorsAndWarnings.errors.map(e => e.message), warnings: utils.errorsAndWarnings.warnings.length };
}

async function main() {
  const [pairsFile, answersFile, mode, count] = process.argv.slice(2);
  const pairs = fs.readFileSync(pairsFile, 'utf8').split('\n').filter(l => l.length > 0).map(l => JSON.parse(l));
  utils.logger.transports[0].silent = true;
  const config = { canonical: settings.canonical, FSHOnly: true, fhirVersion: [settings.fhirVersion], dependencies: undefined, version: settings.version };
  const defs = await createFHIRDefinitions();
  await utils.loadExternalDependencies(defs, config);
  const out = fs.openSync(answersFile, 'w');
  const kept = new Map();
  let n = 0;
  for (const pair of pairs) {
    let answer;
    try {
      const r = compileOnce(fs.readFileSync(pair.file, 'utf8'), defs);
      answer = { id: pair.id, fhir: r.fhir, errors: r.errors, warnings: r.warnings };
    } catch (e) {
      answer = { id: pair.id, crash: String(e && e.message) };
    }
    kept.set(pair.id, answer);
    fs.writeSync(out, JSON.stringify(answer) + '\n');
    if (++n % 500 === 0) process.stderr.write(n + ' texts\n');
  }
  fs.closeSync(out);
  process.stderr.write(n + ' texts compiled\n');
  if (mode === 'check') {
    const step = Math.max(1, Math.floor(pairs.length / Number(count)));
    let checked = 0, differ = 0;
    for (let i = 0; i < pairs.length && checked < Number(count); i += step) {
      const pair = pairs[i];
      const mine = kept.get(pair.id);
      let theirs;
      try {
        const r = await sushiClient.fshToFhir(fs.readFileSync(pair.file, 'utf8'), Object.assign({ logLevel: 'silent' }, settings));
        theirs = { fhir: r.fhir, errors: r.errors.map(e => e.message) };
      } catch (e) { theirs = { crash: String(e && e.message) }; }
      const a = JSON.stringify(mine.crash ? { crash: mine.crash } : { fhir: mine.fhir, errors: mine.errors });
      const b = JSON.stringify(theirs);
      checked++;
      if (a !== b) { differ++; process.stderr.write('differs from sushiClient.fshToFhir: ' + pair.id + '\n'); }
    }
    process.stderr.write('checked ' + checked + ' texts against sushiClient.fshToFhir: ' + differ + ' differ\n');
    process.exitCode = differ === 0 ? 0 : 1;
  }
}

main().catch(e => { process.stderr.write(String(e && e.stack) + '\n'); process.exit(2); });
