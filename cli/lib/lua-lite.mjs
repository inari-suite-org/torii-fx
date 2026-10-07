// A minimal Lua lexer, just enough to read an fxmanifest.lua without being fooled by comments and strings.
//
// Manifests are real Lua, so the CLI can never read every one of them correctly from text. This lexer does two
// things: it blanks comments and long strings (keeping line numbers and short quoted strings), and it reports when
// the manifest uses anything it cannot read safely, so callers can say "check this one by hand" instead of guessing.
// The torii core, which asks FXServer for the real metadata at start, stays the authority.

const blank = (s) => s.replace(/[^\n]/g, ' ');

/**
 * @param {string} text
 * @returns {{ code: string, skeleton: string, longStrings: number, unterminated: number }} `code` has the same length as `text`: comments
 * and long strings are replaced by spaces, quoted strings are kept. `skeleton` is `code` with the content of quoted
 * strings blanked too, so a directive can be located without being fooled by text inside a string.
 */
export function lex(text) {
  let out = '';
  let skeleton = '';
  let longStrings = 0;
  let unterminated = 0;
  let i = 0;
  const n = text.length;
  const longOpen = (at) => /^\[(=*)\[/.exec(text.slice(at, at + 64));
  const skipLong = (at, level) => {
    const close = `]${level}]`;
    const end = text.indexOf(close, at);
    return end === -1 ? n : end + close.length;
  };

  while (i < n) {
    const c = text[i];
    if (c === '-' && text[i + 1] === '-') {
      const open = longOpen(i + 2);
      if (open) {
        const stop = skipLong(i + 2 + open[0].length, open[1]);
        out += blank(text.slice(i, stop));
        skeleton += blank(text.slice(i, stop));
        i = stop;
      } else {
        let end = text.indexOf('\n', i);
        if (end === -1) end = n;
        out += ' '.repeat(end - i);
        skeleton += ' '.repeat(end - i);
        i = end;
      }
      continue;
    }
    if (c === "'" || c === '"') {
      // A short string can continue over several lines: a backslash before a line break (LF, CR, CRLF or LFCR
      // count as one), and \z which skips all the white space that follows, line breaks included.
      let j = i + 1;
      let closed = false;
      while (j < n) {
        const d = text[j];
        if (d === c) {
          closed = true;
          break;
        }
        if (d === '\n' || d === '\r') break; // an unescaped line break: not a valid string
        if (d === '\\') {
          const e = text[j + 1];
          if (e === 'z') {
            j += 2;
            while (j < n && /\s/.test(text[j])) j += 1;
          } else if (e === '\r') {
            j += text[j + 2] === '\n' ? 3 : 2;
          } else if (e === '\n') {
            j += text[j + 2] === '\r' ? 3 : 2;
          } else {
            j += 2;
          }
          continue;
        }
        j += 1;
      }
      if (!closed) unterminated += 1;
      const stop = closed ? j + 1 : j;
      const piece = text.slice(i, stop);
      out += piece;
      skeleton += closed ? c + blank(piece.slice(1, -1)) + c : c + blank(piece.slice(1));
      i = stop;
      continue;
    }
    if (c === '[') {
      const open = longOpen(i);
      if (open) {
        longStrings += 1;
        const stop = skipLong(i + open[0].length, open[1]);
        out += blank(text.slice(i, stop));
        skeleton += blank(text.slice(i, stop));
        i = stop;
        continue;
      }
    }
    out += c;
    skeleton += c;
    i += 1;
  }
  return { code: out, skeleton, longStrings, unterminated };
}

/** Lua constructs that make a manifest's script list depend on something other than literal text. */
const COMPUTED = /\b(for|while|repeat|function|if|local|load|loadstring|dofile|require|setmetatable|_G|_ENV)\b|\.\./;

/**
 * True when a script directive is followed by something that is not a quoted string or a table, or when the
 * manifest uses statements that could compute them.
 */
export function readsUncertainly(code, longStrings) {
  if (longStrings > 0 || COMPUTED.test(code)) return true;
  for (const match of code.matchAll(/\b(shared_scripts?|server_scripts?|client_scripts?)\b\s*(\(\s*)?(\S?)/g)) {
    if (!/['"{]/.test(match[3])) return true;
  }
  return false;
}
