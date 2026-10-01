document.documentElement.classList.add('js');

/* Quiet momentum: scroll reveals and small product demos. Everything is visible without this script. */
(() => {
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const canObserve = 'IntersectionObserver' in window;

  // Reveal only what starts below the fold, so nothing already on screen flashes.
  const reveals = [...document.querySelectorAll('.reveal')];
  // `is-shown` swaps in the quick hover transition, so it waits until the reveal has finished.
  const show = element => {
    if (!element.classList.contains('is-pending') || reduced.matches) {
      element.classList.remove('is-pending');
      element.classList.add('is-shown');
      return;
    }
    element.classList.remove('is-pending');
    let done = false;
    const settle = () => { if (!done) { done = true; element.classList.add('is-shown'); } };
    element.addEventListener('transitionend', event => { if (event.target === element && event.propertyName === 'opacity') settle(); });
    setTimeout(settle, 1200);
  };
  if (!reduced.matches && canObserve) {
    const revealer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        show(entry.target);
        revealer.unobserve(entry.target);
      }
    }, { rootMargin: '0px 0px -8% 0px' });
    let pending = [];
    for (const element of reveals) {
      if (element.getBoundingClientRect().top > innerHeight) {
        element.classList.add('is-pending');
        revealer.observe(element);
        pending.push(element);
      } else {
        element.classList.add('is-shown');
      }
    }
    // Belt and braces: a plain geometry check on scroll, so nothing can stay hidden if an observer is late.
    const check = () => {
      pending = pending.filter(element => {
        if (!element.classList.contains('is-pending')) return false;
        if (element.getBoundingClientRect().top < innerHeight * .92) { show(element); revealer.unobserve(element); return false; }
        return true;
      });
      if (!pending.length) { removeEventListener('scroll', check); removeEventListener('resize', check); }
    };
    if (pending.length) { addEventListener('scroll', check, { passive: true }); addEventListener('resize', check); }
  } else {
    reveals.forEach(show);
  }
  reduced.addEventListener('change', () => { if (reduced.matches) reveals.forEach(show); });

  if (!canObserve) return;

  // A pausable list of [wait, action] steps.
  const makeRunner = () => {
    let steps = [];
    let index = 0;
    let timer = 0;
    let paused = true;
    const tick = () => {
      while (!paused && !timer && index < steps.length && steps[index][0] === 0) steps[index++][1]();
      if (paused || timer || index >= steps.length) return;
      timer = setTimeout(() => {
        timer = 0;
        const [, action] = steps[index++];
        action();
        tick();
      }, steps[index][0]);
    };
    return {
      play(list) { clearTimeout(timer); timer = 0; steps = list; index = 0; paused = false; tick(); },
      pause() { paused = true; clearTimeout(timer); timer = 0; },
      resume() { paused = false; tick(); },
      get started() { return steps.length > 0; },
      get done() { return index >= steps.length; }
    };
  };

  // Runs a demo only while it is on screen in an active tab. With `rearm`, it plays again after leaving the screen.
  const demo = (element, { build, finish, threshold = .45, rearm = true }) => {
    const runner = makeRunner();
    let visible = false;
    let armed = true;
    // Start from the empty first frame while still off screen, so the final state never flashes first.
    if (!reduced.matches) { element.classList.add('is-live'); build()[0][1](); }
    const sync = () => {
      const run = visible && !document.hidden && !reduced.matches;
      if (!run) { runner.pause(); return; }
      if (armed) {
        armed = false;
        element.classList.add('is-live');
        runner.play(build());
      } else {
        runner.resume();
      }
    };
    new IntersectionObserver(([entry]) => {
      visible = entry.intersectionRatio >= threshold;
      if (!entry.isIntersecting && rearm && runner.done) armed = true;
      sync();
    }, { threshold: [0, threshold] }).observe(element);
    document.addEventListener('visibilitychange', sync);
    reduced.addEventListener('change', () => {
      if (!reduced.matches) return;
      runner.pause();
      element.classList.remove('is-live');
      finish();
    });
    return { runner, element, sync };
  };

  const stepsIn = (root, on) => root.querySelectorAll('.step').forEach(step => step.classList.toggle('is-in', on));

  // Approve right in the chat: a prompt is typed and sent, Cove answers with a card, and the event is added.
  const chat = document.querySelector('.chat-window');
  if (chat) {
    const scenes = [...chat.querySelectorAll('.scene')];
    const controls = document.querySelector('.chat-controls');
    const buttons = controls ? [...controls.querySelectorAll('button')] : [];
    const listItems = [...document.querySelectorAll('.approve-list [data-scene]')];
    const input = chat.querySelector('.composer-input');
    const send = chat.querySelector('.send');
    const cursor = chat.querySelector('.demo-cursor');
    const placeholder = input.textContent;

    const setScene = active => {
      scenes.forEach((scene, i) => scene.classList.toggle('is-active', i === active));
      buttons.forEach((button, i) => button.setAttribute('aria-pressed', String(i === active)));
      listItems.forEach(item => item.classList.toggle('is-active', Number(item.dataset.scene) === active));
    };
    const setInput = text => {
      input.textContent = text || placeholder;
      input.classList.toggle('has-text', Boolean(text));
      send.classList.toggle('is-ready', Boolean(text));
    };
    const settle = scene => {
      stepsIn(scene, true);
      scene.querySelector('.thinking')?.classList.remove('is-on');
      scene.classList.toggle('is-added', scene.dataset.final === 'added');
      scene.querySelectorAll('.is-pressed').forEach(el => el.classList.remove('is-pressed'));
    };
    const reset = scene => {
      stepsIn(scene, false);
      scene.classList.remove('is-added');
      scene.querySelector('.thinking')?.classList.remove('is-on');
      scene.querySelectorAll('.is-pressed').forEach(el => el.classList.remove('is-pressed'));
    };
    const place = (target, instant) => {
      const box = chat.getBoundingClientRect();
      const rect = target.getBoundingClientRect();
      if (instant) cursor.classList.add('no-move');
      cursor.style.setProperty('--cx', `${Math.round(rect.left - box.left + rect.width * .5)}px`);
      cursor.style.setProperty('--cy', `${Math.round(rect.top - box.top + rect.height * .45)}px`);
      if (instant) { void cursor.offsetWidth; cursor.classList.remove('no-move'); }
    };
    const hideCursor = () => cursor.classList.remove('is-on', 'is-press');

    const sceneSteps = i => {
      const scene = scenes[i];
      const bubble = scene.querySelector('.bubble');
      const text = bubble.textContent.trim();
      const thinking = scene.querySelector('.thinking');
      const steps = [[0, () => { hideCursor(); setScene(i); reset(scene); setInput(''); input.classList.add('is-typing'); }]];
      for (let n = 1; n <= text.length; n += 1) {
        steps.push([n === 1 ? 700 : (text[n - 2] === ' ' ? 90 : 42), () => setInput(text.slice(0, n))]);
      }
      steps.push([500, () => { input.classList.remove('is-typing'); send.classList.add('is-pressed'); }]);
      steps.push([160, () => { send.classList.remove('is-pressed'); setInput(''); bubble.classList.add('is-in'); }]);
      if (thinking) {
        steps.push([450, () => thinking.classList.add('is-on')]);
        steps.push([1500, () => thinking.classList.remove('is-on')]);
      }
      const later = [...scene.querySelectorAll('.step')].filter(step => step !== bubble);
      later.forEach((step, n) => steps.push([n === 0 ? 250 : 520, () => step.classList.add('is-in')]));
      if (scene.dataset.final === 'added') {
        const add = scene.querySelector('.add');
        const start = scene.querySelector('.not-now');
        steps.push([900, () => { place(start, true); cursor.classList.add('is-on'); }]);
        steps.push([250, () => place(add, false)]);
        steps.push([1100, () => { cursor.classList.add('is-press'); add.classList.add('is-pressed'); }]);
        steps.push([220, () => { cursor.classList.remove('is-press'); add.classList.remove('is-pressed'); scene.classList.add('is-added'); }]);
        steps.push([900, hideCursor]);
      }
      steps.push([i === scenes.length - 1 ? 0 : 3400, () => {}]);
      return steps;
    };
    const from = start => {
      const steps = [];
      for (let i = start; i < scenes.length; i += 1) steps.push(...sceneSteps(i));
      return steps;
    };
    const finish = () => {
      hideCursor();
      setInput('');
      input.classList.remove('is-typing');
      scenes.forEach(settle);
    };

    finish();
    setScene(0);
    const chatDemo = demo(chat, { build: () => from(0), finish: () => { finish(); }, threshold: .4, rearm: false });
    if (controls) {
      controls.hidden = false;
      buttons.forEach((button, i) => button.addEventListener('click', () => {
        if (reduced.matches) { finish(); setScene(i); return; }
        chat.classList.add('is-live');
        chatDemo.runner.play(from(i));
        if (document.hidden) chatDemo.runner.pause();
      }));
    }
  }

  // Exact count: the number ticks up to its final value, then the search it used and the newest matches.
  const count = document.querySelector('.count-demo');
  if (count) {
    const number = count.querySelector('.count-num');
    const final = Number(number.dataset.final);
    const [bubble, result, query, ...rows] = count.querySelectorAll('.step');
    demo(count, {
      build: () => {
        const steps = [[0, () => { stepsIn(count, false); number.textContent = '0'; }], [300, () => bubble.classList.add('is-in')], [700, () => result.classList.add('is-in')]];
        for (let n = 1; n <= final; n += 1) steps.push([n === 1 ? 250 : 45 + n * 6, () => { number.textContent = String(n); }]);
        steps.push([350, () => query.classList.add('is-in')]);
        rows.forEach(row => steps.push([160, () => row.classList.add('is-in')]));
        return steps;
      },
      finish: () => { stepsIn(count, true); number.textContent = String(final); }
    });
  }

  // Calendar drag: an event is picked up, moved to another day and resized, with its time label following.
  const drag = document.querySelector('.drag-demo');
  if (drag) {
    const label = drag.querySelector('.drag-label');
    const cursor = drag.querySelector('.drag-cursor');
    const toast = drag.querySelector('.drag-toast');
    const finalLabel = label.textContent;
    demo(drag, {
      build: () => [
        [0, () => { drag.dataset.state = 'start'; label.textContent = 'Wed · 10:00 – 10:30 AM'; toast.classList.remove('is-in'); cursor.classList.remove('is-on', 'is-edge'); drag.classList.remove('is-grabbed'); }],
        [600, () => cursor.classList.add('is-on')],
        [600, () => drag.classList.add('is-grabbed')],
        [350, () => { drag.dataset.state = 'moved'; }],
        [600, () => { label.textContent = 'Thu · 11:00 – 11:30 AM'; }],
        [600, () => drag.classList.remove('is-grabbed')],
        [500, () => cursor.classList.add('is-edge')],
        [700, () => { delete drag.dataset.state; }],
        [500, () => { label.textContent = finalLabel; }],
        [600, () => { cursor.classList.remove('is-on', 'is-edge'); toast.classList.add('is-in'); }]
      ],
      finish: () => { delete drag.dataset.state; label.textContent = finalLabel; toast.classList.add('is-in'); cursor.classList.remove('is-on', 'is-edge'); drag.classList.remove('is-grabbed'); }
    });
  }

  // Agent editor: the three steps highlight in order.
  const editor = document.querySelector('.agent-editor');
  if (editor) {
    const steps = [...editor.querySelectorAll('.ae-step')];
    const mark = current => steps.forEach((step, i) => {
      step.classList.toggle('is-current', i === current);
      step.classList.toggle('is-done', i < current);
    });
    demo(editor, {
      build: () => [[0, () => mark(-1)], [500, () => mark(0)], [1900, () => mark(1)], [2100, () => mark(2)], [1700, () => mark(steps.length)]],
      finish: () => steps.forEach(step => step.classList.remove('is-current', 'is-done'))
    });
  }

  // Agents portrait: a real photo as dots on the dark card. Dot size follows the light, so the lit side
  // is drawn and the shadow side fades into the dark; a soft line sweeps down as if reading.
  const portrait = document.querySelector('.portrait-canvas');
  if (portrait) {
    const context = portrait.getContext('2d');
    const image = new Image();
    let dots = [];
    let height = 0;
    let visible = false;
    let frame = 0;
    let last = 0;
    const tones = 8;
    const layout = () => {
      const box = portrait.getBoundingClientRect();
      const ratio = window.devicePixelRatio || 1;
      const width = Math.max(1, Math.round(box.width));
      height = Math.max(1, Math.round(box.height));
      portrait.width = width * ratio; portrait.height = height * ratio;
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      if (!image.naturalWidth) return;
      const sample = document.createElement('canvas');
      sample.width = width; sample.height = height;
      const pen = sample.getContext('2d', { willReadFrequently: true });
      pen.fillStyle = '#000'; pen.fillRect(0, 0, width, height);
      const drawnWidth = height * image.naturalWidth / image.naturalHeight;
      pen.drawImage(image, (width - drawnWidth) / 2, 0, drawnWidth, height);
      const pixels = pen.getImageData(0, 0, width, height).data;
      const spacing = Math.max(3.4, height / 72);
      const reach = Math.max(1, Math.floor(spacing / 2));
      dots = [];
      for (let y = spacing / 2, row = 0; y < height; y += spacing * .9, row++) {
        for (let x = spacing / 2 + (row % 2 ? spacing / 2 : 0); x < width; x += spacing) {
          let total = 0, count = 0;
          for (let dy = -reach; dy <= reach; dy++) for (let dx = -reach; dx <= reach; dx++) {
            const sx = Math.round(x) + dx, sy = Math.round(y) + dy;
            if (sx < 0 || sy < 0 || sx >= width || sy >= height) continue;
            total += pixels[(sy * width + sx) * 4] / 255; count++;
          }
          const ink = Math.pow(Math.min(1, Math.max(0, ((count ? total / count : 0) - .16) / .72)), 1.9);
          if (ink > .07) dots.push([x, y, ink]);
        }
      }
      draw(0);
    };
    const draw = time => {
      context.clearRect(0, 0, portrait.width, portrait.height);
      const scan = ((time / 1000) % 9) / 9 * height * 1.4 - height * .2;
      const paths = Array.from({ length: tones }, () => new Path2D());
      for (const [x, y, ink] of dots) {
        const near = Math.exp(-Math.pow((y - scan) / 16, 2));
        const lit = Math.min(1, ink + (time ? near * .22 : 0));
        const radius = .5 + 1.05 * lit;
        const path = paths[Math.min(tones - 1, Math.floor(lit * tones))];
        path.moveTo(x + radius, y); path.arc(x, y, radius, 0, Math.PI * 2);
      }
      paths.forEach((path, index) => {
        const shade = Math.round(255 * (.72 + .03 * index));
        context.fillStyle = `rgba(${shade},${shade},${Math.min(255, shade + 4)},${.18 + .1 * index})`;
        context.fill(path);
      });
    };
    const loop = time => {
      frame = 0;
      if (!visible || document.hidden || reduced.matches) return;
      if (time - last > 66) { last = time; draw(time); }
      frame = requestAnimationFrame(loop);
    };
    const sync = () => { if (!frame && visible && !document.hidden && !reduced.matches) frame = requestAnimationFrame(loop); };
    image.addEventListener('load', layout);
    image.src = '/assets/agent-portrait.jpg';
    addEventListener('resize', () => { layout(); });
    new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); }).observe(portrait);
    document.addEventListener('visibilitychange', sync);

    // Captions: what agents do, one at a time, the newest in the accent color.
    const captions = document.querySelector('.portrait-captions');
    if (captions) {
      const lines = ['Invoice #2048 from Acme → Finance / Invoices', 'Client asks about next week’s delivery → reply drafted',
        '“Can we find 30 minutes?” → reply drafted', 'Flight confirmation → Travel', 'New application for Designer → Hiring'];
      const now = captions.querySelector('.cap-now');
      const next = captions.querySelector('.cap-next');
      let index = 0;
      setInterval(() => {
        if (!visible || document.hidden || reduced.matches) return;
        captions.classList.add('is-changing');
        setTimeout(() => {
          index = (index + 1) % lines.length;
          now.textContent = lines[index];
          next.textContent = lines[(index + 1) % lines.length];
          captions.classList.remove('is-changing');
        }, 450);
      }, 3600);
    }
  }

  // Describe it: the sentence is typed, then the steps and the try-it result appear in order.
  const planMock = document.querySelector('.plan-mock');
  if (planMock) {
    const typed = planMock.querySelector('.pm-typed');
    const full = typed.textContent;
    const parts = [...planMock.querySelectorAll('.pm-card, .pm-foot')];
    const show = on => parts.forEach(part => part.classList.toggle('is-in', on));
    demo(planMock, {
      build: () => {
        const steps = [[0, () => { typed.textContent = ''; show(false); }]];
        for (let i = 4; i <= full.length + 3; i += 4) steps.push([45, () => { typed.textContent = full.slice(0, i); }]);
        parts.forEach((part, i) => steps.push([i ? 520 : 700, () => part.classList.add('is-in')]));
        return steps;
      },
      finish: () => { typed.textContent = full; show(true); }
    });
  }

  // Install demo (beta page): the Cove icon breaks into dots that travel the arc into Applications.
  const install = document.querySelector('.install-canvas');
  if (install) {
    const pen = install.getContext('2d');
    const icon = new Image();
    const W = 560, H = 220, size = 96, appX = 120, folderX = 440, midY = 108;
    const tide = ['#78d9c9', '#8abaf0', '#baa1ed', '#e6a8c9', '#f2bd8c'];
    const period = 4600;
    let particles = [];
    let visible = false, frame = 0, began = 0;
    const ratio = window.devicePixelRatio || 1;
    install.width = W * ratio; install.height = H * ratio;
    pen.setTransform(ratio, 0, 0, ratio, 0, 0);
    const ease = x => { x = Math.min(1, Math.max(0, x)); return x * x * (3 - 2 * x); };
    const arc = p => [appX + 64 + (folderX - appX - 64) * p, midY + 6 - Math.sin(p * Math.PI) * 34];
    const sample = () => {
      const c = document.createElement('canvas'); c.width = c.height = 24;
      const g = c.getContext('2d', { willReadFrequently: true }); g.drawImage(icon, 0, 0, 24, 24);
      const data = g.getImageData(0, 0, 24, 24).data;
      particles = [];
      for (let y = 0; y < 24; y++) for (let x = 0; x < 24; x++) {
        const i = (y * 24 + x) * 4;
        if (data[i + 3] < 120) continue;
        particles.push({ x: appX - size / 2 + (x + .5) * size / 24, y: midY - size / 2 + (y + .5) * size / 24,
          color: `rgb(${data[i]},${data[i + 1]},${data[i + 2]})`, delay: Math.random() * .35, lift: (Math.random() - .5) * 26 });
      }
    };
    const folder = (bounce, glow) => {
      const w = 104 * bounce, h = 80 * bounce, x = folderX - w / 2, y = midY - h / 2 + 4;
      pen.save();
      pen.fillStyle = '#cfe0f7'; pen.beginPath(); pen.roundRect(x, y - 10 * bounce, w * .42, 22 * bounce, 6); pen.fill();
      const fill = pen.createLinearGradient(0, y, 0, y + h);
      fill.addColorStop(0, '#a9cbf5'); fill.addColorStop(1, '#8abaf0');
      pen.fillStyle = fill; pen.beginPath(); pen.roundRect(x, y, w, h, 9); pen.fill();
      if (glow > 0) { pen.globalAlpha = glow; pen.fillStyle = '#fff'; pen.beginPath(); pen.arc(folderX, midY + 6, 9 * bounce, 0, Math.PI * 2); pen.fill(); }
      pen.restore();
      pen.fillStyle = '#5d626b'; pen.font = '500 12px Inter, system-ui, sans-serif'; pen.textAlign = 'center';
      pen.fillText('Applications', folderX, midY + 72);
    };
    const guide = alpha => {
      for (let i = 0; i <= 14; i++) {
        const p = i / 14 * .8, [x, y] = arc(p);
        pen.globalAlpha = alpha * (.25 + .5 * p); pen.fillStyle = tide[Math.min(4, Math.floor(p * 5))];
        pen.beginPath(); pen.arc(x, y, 1.4 + 1.6 * p, 0, Math.PI * 2); pen.fill();
      }
      pen.globalAlpha = 1;
    };
    const draw = t => {
      const time = t % period;
      pen.clearRect(0, 0, W, H);
      const dissolve = ease((time - 600) / 500);          // the icon gives way to its dots
      const travel = (time - 1000) / 1500;                 // the dots cross to the folder
      const land = ease((time - 2500) / 350) * (1 - ease((time - 2850) / 350));
      const reform = ease((time - 3500) / 700);            // the icon comes back for the next loop
      guide(1 - Math.min(1, Math.max(0, travel)) * (1 - reform) * .7);
      if (time < 1000 || reform > 0) {
        pen.globalAlpha = time < 1000 ? 1 - dissolve : reform;
        pen.drawImage(icon, appX - size / 2, midY - size / 2, size, size);
        pen.globalAlpha = 1;
      }
      pen.fillStyle = '#5d626b'; pen.font = '500 12px Inter, system-ui, sans-serif'; pen.textAlign = 'center';
      pen.globalAlpha = time < 1000 ? 1 : reform; pen.fillText('Cove', appX, midY + 72); pen.globalAlpha = 1;
      if (time >= 600 && time < 3000) {
        particles.forEach((d, i) => {
          const p = ease((travel - d.delay) / .65);
          const [ax, ay] = arc(p);
          const sx = d.x + (ax - d.x) * Math.min(1, p * 1.6), sy = d.y + (ay - d.y) * Math.min(1, p * 1.6) + Math.sin(p * Math.PI) * d.lift;
          const x = sx, y = sy;
          pen.globalAlpha = Math.max(dissolve, .2) * .95;
          pen.fillStyle = p > .15 ? tide[Math.min(4, Math.floor(p * 5))] : d.color;
          pen.beginPath(); pen.arc(x, y, 2.2 - p * .9, 0, Math.PI * 2); pen.fill();
        });
        pen.globalAlpha = 1;
      }
      folder(1 + land * .07, land * .6);
    };
    const loop = t => {
      frame = 0;
      if (!visible || document.hidden || reduced.matches) return;
      if (!began) began = t;
      draw(t - began);
      frame = requestAnimationFrame(loop);
    };
    const sync = () => {
      if (!icon.naturalWidth) return;
      if (reduced.matches) { draw(0); return; }
      if (!frame && visible && !document.hidden) frame = requestAnimationFrame(loop);
    };
    // ?install=<ms> draws one fixed moment, for checking the animation in screenshots.
    const fixed = new URLSearchParams(location.search).get('install');
    icon.addEventListener('load', () => { sample(); draw(Number(fixed) || 0); if (fixed === null) sync(); });
    icon.src = '/assets/cove-icon.png';
    if (fixed === null) {
      new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync(); }).observe(install);
      document.addEventListener('visibilitychange', sync);
    }
  }
})();
