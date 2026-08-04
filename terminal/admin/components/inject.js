export function createInject(root, { api, visible }) {
  if (!visible) {
    root.closest('#injectPanel')?.setAttribute('hidden', '');
    return { destroy() {} };
  }
  root.closest('#injectPanel')?.removeAttribute('hidden');

  root.innerHTML = `
    <div class="inject-grid">
      <button type="button" class="btn" data-inject="PersonDetected">Person enters</button>
      <button type="button" class="btn" data-inject="PersonAbsent">Person leaves</button>
      <button type="button" class="btn" data-inject="FaceUnknown">Unknown face</button>
      <button type="button" class="btn" data-inject="WakeWord">Wake word</button>
      <button type="button" class="btn" data-inject="PlaybackEnded">Playback ended</button>
      <button type="button" class="btn" id="faceOk">Recognise as</button>
      <input id="faceUser" type="text" value="zlatko" style="width:7rem;font:400 12px var(--font-mono);background:var(--surface-2);border:1px solid var(--border);border-radius:6px;color:var(--fg);padding:8px" />
    </div>
    <div class="inject-transcript">
      <input id="transcript" type="text" placeholder="TranscriptReady" />
      <button type="button" class="btn" id="sendTranscript">Send</button>
    </div>
    <p class="action-err" id="injectErr" hidden></p>
  `;

  async function inject(event, extra = {}) {
    const err = root.querySelector('#injectErr');
    err.hidden = true;
    try {
      await api.post('/inject', { event, ...extra });
    } catch (e) {
      err.hidden = false;
      err.textContent = e.message || String(e);
    }
  }

  root.querySelectorAll('[data-inject]').forEach((btn) => {
    btn.addEventListener('click', () => inject(btn.getAttribute('data-inject')));
  });
  root.querySelector('#faceOk').addEventListener('click', () => {
    inject('FaceRecognized', {
      userid: root.querySelector('#faceUser').value.trim() || 'zlatko',
      confidence: 0.9,
    });
  });
  const transcript = root.querySelector('#transcript');
  const send = () => {
    const text = transcript.value.trim();
    if (!text) return;
    inject('TranscriptReady', { text });
  };
  root.querySelector('#sendTranscript').addEventListener('click', send);
  transcript.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') send();
  });
  transcript.focus();

  return { destroy() {} };
}
