import { pct } from '../lib/fmt.js';

function sparkSvg(samples, high = 80) {
  const w = 120;
  const h = 28;
  const n = samples.length || 1;
  const barW = Math.max(1, Math.floor(w / Math.max(n, 1)));
  let x = 0;
  const rects = samples.map((v) => {
    const val = Math.max(0, Math.min(100, Number(v) || 0));
    const bh = Math.max(1, (val / 100) * h);
    const color = val >= high ? '#F0A202' : '#3DDCFF';
    const y = h - bh;
    const r = `<rect x="${x}" y="${y.toFixed(1)}" width="${barW - 1}" height="${bh.toFixed(1)}" fill="${color}"/>`;
    x += barW;
    return r;
  }).join('');
  return `<svg class="metric__spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" aria-hidden="true">${rects}</svg>`;
}

export function createHealth(rootGrid, rootMetrics) {
  const cpuHist = [];
  const memHist = [];

  function card(label, value, detail, tone) {
    const toneClass = tone === 'red' ? 'is-red' : tone === 'amber' ? 'is-amber' : '';
    return `<div class="health-card ${toneClass}">
      <div class="health-card__label">${label}</div>
      <div class="health-card__value">${value}</div>
      <div class="health-card__detail">${detail || ''}</div>
    </div>`;
  }

  function probeTone(ok, ms) {
    if (!ok) return 'red';
    if (ms != null && ms > 1000) return 'red';
    if (ms != null && ms > 200) return 'amber';
    return 'cyan';
  }

  function render(status) {
    const units = status.units || {};
    const aoOk = !!status.ao_ok;
    const cpaiOk = !!status.cpai_ok;
    const kiosk = !!status.kiosk_connected;
    const audio = !!status.audio_connected;
    const stt = units.stt !== false;
    const channelConfigured = status.channel_url != null && status.channel_url !== '';
    const channelOk = status.channel_ok;

    const cards = [
      card('AO', aoOk ? 'ok' : 'fail', status.ao_url ? 'reach' : '', probeTone(aoOk)),
      card('CPAI', cpaiOk ? 'ok' : 'fail', '', probeTone(cpaiOk)),
      card('STT', stt ? 'ok' : 'down', '', stt ? 'cyan' : 'red'),
      card('Kiosk', kiosk ? 'conn' : 'down', '', kiosk ? 'cyan' : 'red'),
      card('Audio', audio ? 'conn' : 'down', '', audio ? 'cyan' : 'red'),
    ];
    if (channelConfigured) {
      const ok = !!channelOk;
      cards.push(
        card('Channel', ok ? 'ok' : 'fail', 'telegram', probeTone(ok)),
      );
    }
    rootGrid.innerHTML = cards.join('');

    if (status.cpu != null) {
      cpuHist.push(Number(status.cpu));
      if (cpuHist.length > 60) cpuHist.shift();
    }
    if (status.mem != null) {
      memHist.push(Number(status.mem));
      if (memHist.length > 60) memHist.shift();
    }

    rootMetrics.innerHTML = `
      <div class="metric">
        <div class="metric__label">CPU</div>
        <div class="metric__value">${pct(status.cpu)}</div>
        ${sparkSvg(cpuHist)}
      </div>
      <div class="metric">
        <div class="metric__label">Mem</div>
        <div class="metric__value">${pct(status.mem)}</div>
        ${sparkSvg(memHist)}
      </div>`;
  }

  return { render };
}
