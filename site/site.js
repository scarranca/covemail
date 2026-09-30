const review = document.querySelector('#draft-review');
const trigger = document.querySelector('#review-demo');
if (review && trigger) {
  trigger.addEventListener('click', () => review.showModal());
  review.addEventListener('click', event => { if (event.target === review) { const rect = review.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) review.close(); } });
  review.addEventListener('close', () => trigger.focus());
}

/* Quiet momentum: scroll reveals and two small product demos. Everything is visible without this script. */
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

  // Search as you type: rows dim in place (no layout shift) while a query is typed and cleared.
  const search = document.querySelector('.search-demo');
  if (search && canObserve) {
    const query = search.querySelector('.search-query');
    const count = search.querySelector('.search-count');
    const list = search.querySelector('.search-list');
    const rows = [...list.querySelectorAll('li')];
    const finalQuery = query.dataset.final;
    const queries = [finalQuery, 'maya', 'notes'];
    let visible = false;
    let timer = 0;
    let index = 0;
    let typed = '';
    let deleting = false;
    const render = () => {
      query.textContent = typed;
      const needle = typed.trim().toLowerCase();
      let matches = 0;
      for (const row of rows) {
        const hit = needle.length > 0 && row.dataset.text.toLowerCase().includes(needle);
        row.classList.toggle('is-match', hit);
        if (hit) matches += 1;
      }
      list.classList.toggle('is-filtering', needle.length > 0);
      count.textContent = needle ? `${matches} ${matches === 1 ? 'match' : 'matches'}` : '';
    };
    const restoreFinal = () => { typed = finalQuery; render(); search.classList.remove('is-live'); };
    const tick = () => {
      timer = 0;
      if (!visible || document.hidden || reduced.matches) return;
      const target = queries[index % queries.length];
      let wait;
      if (!deleting) {
        typed = target.slice(0, typed.length + 1);
        wait = typed === target ? 2100 : 95 + Math.random() * 70;
        if (typed === target) deleting = true;
      } else {
        typed = typed.slice(0, -1);
        wait = typed ? 40 : 520;
        if (!typed) { deleting = false; index += 1; }
      }
      render();
      timer = setTimeout(tick, wait);
    };
    const sync = () => {
      const run = visible && !document.hidden && !reduced.matches;
      if (run && !timer) {
        if (!search.classList.contains('is-live')) {
          search.classList.add('is-live');
          typed = '';
          deleting = false;
          index = 0;
          render();
        }
        timer = setTimeout(tick, 450);
      } else if (!run && timer) {
        clearTimeout(timer);
        timer = 0;
      }
      if (reduced.matches) restoreFinal();
    };
    new IntersectionObserver(entries => { visible = entries[0].isIntersecting; sync(); }, { threshold: .35 }).observe(search);
    document.addEventListener('visibilitychange', sync);
    reduced.addEventListener('change', sync);
  }

  // A draft that streams in word by word, the first time it is seen, with a replay.
  const stream = document.querySelector('.stream-text');
  const replay = document.querySelector('.stream-demo ~ .replay');
  if (stream && canObserve) {
    const words = stream.textContent.trim().split(/\s+/);
    stream.textContent = '';
    const spans = words.map((word, i) => {
      const span = document.createElement('span');
      span.className = 'word';
      span.textContent = word;
      stream.append(span);
      if (i < words.length - 1) stream.append(' ');
      return span;
    });
    let timers = [];
    const play = () => {
      timers.forEach(clearTimeout);
      timers = [];
      if (reduced.matches) return;
      spans.forEach(span => span.classList.remove('is-in'));
      stream.classList.add('is-streaming');
      if (replay) replay.classList.remove('is-ready');
      let delay = 350;
      spans.forEach((span, i) => {
        delay += /[.,]$/.test(words[i - 1] || '') ? 180 : 62;
        timers.push(setTimeout(() => span.classList.add('is-in'), delay));
      });
      timers.push(setTimeout(() => {
        stream.classList.remove('is-streaming');
        spans.forEach(span => span.classList.remove('is-in'));
        if (replay) replay.classList.add('is-ready');
      }, delay + 700));
    };
    if (!reduced.matches) {
      const watcher = new IntersectionObserver(entries => {
        if (!entries[0].isIntersecting) return;
        watcher.disconnect();
        play();
      }, { threshold: .5 });
      watcher.observe(stream);
      if (replay) { replay.hidden = false; replay.addEventListener('click', play); }
    }
    reduced.addEventListener('change', () => {
      if (!reduced.matches) return;
      timers.forEach(clearTimeout);
      stream.classList.remove('is-streaming');
    });
  }
})();
