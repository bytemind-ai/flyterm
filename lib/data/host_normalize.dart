// SPDX-License-Identifier: GPL-3.0-or-later
/// Normalise a user-entered host string before storing it in the
/// Server model.
///
/// Trims surrounding whitespace and strips a single matched pair of
/// square brackets that wraps the entire value — Dart's `Socket.connect`
/// expects bare IPv6 literals (`2001:db8::1`), but it's natural for
/// users to paste the URL form (`[2001:db8::1]`) so both forms are
/// accepted silently.
///
/// Brackets that don't form a clean wrapper (e.g., `foo[bar]`,
/// `[2001:db8::1`, `1.2.3.4]`) are left in place; the connection
/// layer will surface the resulting error rather than us guessing.
String normalizeHost(String input) {
  var h = input.trim();
  if (h.length >= 2 && h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1).trim();
  }
  return h;
}
