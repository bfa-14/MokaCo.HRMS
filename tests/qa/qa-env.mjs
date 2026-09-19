/* tests/qa/qa-env.mjs — where the Node scripts get the SQL connection from. NO CREDENTIAL LIVES IN
   THE REPO: SQLCMDSERVER / SQLCMDUSER / SQLCMDPASSWORD come from the environment, or from
   tests/qa/.env (gitignored; copy .env.example). A value already in the environment wins.
   The password reaches sqlcmd through its environment, never through -P: an argument is readable
   by every user of the machine in the process list. */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const KEYS = ['SQLCMDSERVER', 'SQLCMDUSER', 'SQLCMDPASSWORD'];
const file = join(dirname(fileURLToPath(import.meta.url)), '.env');
if (existsSync(file)) {
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const at = line.indexOf('=');
    if (at < 1 || line.trimStart().startsWith('#')) continue;
    const key = line.slice(0, at).trim();
    if (KEYS.includes(key) && !process.env[key]) process.env[key] = line.slice(at + 1);
  }
}
const missing = KEYS.filter((key) => !process.env[key]);
if (missing.length) {
  console.error(`tests/qa: ${missing.join(', ')} not set. Export them, or copy tests/qa/.env.example to tests/qa/.env and fill it in.`);
  process.exit(2);
}

/** The connection part of every sqlcmd call; the password travels in the inherited environment. */
export const SQLCMD_CONNECTION = ['-S', process.env.SQLCMDSERVER, '-U', process.env.SQLCMDUSER, '-C', '-I', '-d', 'MokaCo_HRMS'];
