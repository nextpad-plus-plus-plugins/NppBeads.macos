const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const viewer = path.join(__dirname, '../resources/viewer');
const context = vm.createContext({
  window: { addEventListener() {} },
  document: {
    documentElement: { dataset: {} },
    addEventListener() {},
  },
  console: { log() {} },
});
vm.runInContext(fs.readFileSync(path.join(viewer, 'field-content.js'), 'utf8'), context);
vm.runInContext(fs.readFileSync(path.join(viewer, 'app/app.js'), 'utf8'), context);

test('JSON planning fields are indented and HTML-escaped', () => {
  const text = '{"approach":["</code><img src=x onerror=alert(1)>","A&B"]}';
  const html = context.renderBeadField(text, () => assert.fail('JSON must stay literal'));
  assert.equal(html, '<pre class="bead-json"><code>{\n  "approach": [\n    "&lt;/code&gt;&lt;img src=x onerror=alert(1)&gt;",\n    "A&amp;B"\n  ]\n}</code></pre>');
});

test('Markdown and incomplete JSON use the existing sanitized Markdown renderer', () => {
  for (const text of ['## Design\n\n- First step', '{"approach":']) {
    let calls = 0;
    assert.equal(context.renderBeadField(text, source => {
      assert.equal(source, text);
      calls++;
      return '<p>sanitized output</p>';
    }), '<p>sanitized output</p>');
    assert.equal(calls, 1);
  }
});

test('empty planning fields have no rendered content', () => {
  assert.equal(context.renderBeadField(' \n\t', () => assert.fail('empty field')), '');
});

test('JSONL loading preserves planning fields and defaults absent fields to empty text', () => {
  const App = context.window.__nppApp;
  const bead = {
    id: 'test-1',
    description: 'Existing description',
    design: '{"approach":["Synthetic example"]}',
    acceptance_criteria: '- The design is visible',
    notes: '**Review** the implementation',
  };
  App.load(JSON.stringify(bead) + '\n' + JSON.stringify({ id: 'test-2' }));
  for (const key of ['description', 'design', 'acceptance_criteria', 'notes']) {
    assert.equal(App.beads[0][key], bead[key]);
    assert.equal(App.beads[1][key], '');
  }
});
