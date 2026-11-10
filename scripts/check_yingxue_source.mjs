import { readFileSync } from 'node:fs';
import { inspectSourceFile } from '../protocols/yingxue/source-file.mjs';

if (process.argv.length !== 3 && !(process.argv.length === 5 && process.argv[3] === '--previous')) {
  process.stderr.write('Usage: node scripts/check_yingxue_source.mjs <file.source.js> [--previous <installed.source.js>]\n');
  process.exitCode = 2;
} else {
  try {
    const result = inspectSourceFile(readFileSync(process.argv[2]), {previousBytes: process.argv.length === 5 ? readFileSync(process.argv[4]) : undefined});
    process.stdout.write(JSON.stringify({
      scope: 'static-metadata-and-module-only',
      sourceID: result.manifest.sourceID,
      protocolVersion: result.manifest.protocolVersion,
      scriptSHA256: result.scriptSHA256,
      ...result.report,
      ...(result.upgrade ? {upgrade: result.upgrade} : {}),
    }, null, 2) + '\n');
    if (result.report.kind !== 'accepted') process.exitCode = 1;
  } catch (error) {
    // Only known parser categories are shareable. Filesystem errors may include paths.
    const safe = /^(?:\$(?:\.[A-Za-z]+|\[\d+\])*: [A-Za-z]+|invalidUTF8|missingHeader|unclosedHeader|missingModule|duplicateOrigin|missingOrigins|duplicateSetting|invalidChoice|invalidPreviousSource|differentSource)$/;
    process.stderr.write(JSON.stringify({kind: 'rejected', reason: safe.test(error.message) ? error.message : 'inspectionFailed'}) + '\n');
    process.exitCode = 1;
  }
}
