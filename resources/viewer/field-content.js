function renderBeadField(text, markdownRenderer) {
  if (!text.trim()) return '';
  let json;
  try {
    json = JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return markdownRenderer(text);
  }
  const escaped = json.replace(/&/g, '&amp;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return '<pre class="bead-json"><code>' + escaped + '</code></pre>';
}
