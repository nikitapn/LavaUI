// Click-to-enlarge for images wrapped in <a data-lightbox href="full.jpg">.
//
// The link is the fallback: without this script it simply opens the image.
// With it, the picture opens in a native <dialog> — Esc, focus trapping and
// the backdrop come with the element. Delegated from the document, because
// htmx swaps page bodies in and a listener bound to the link would go with it.

let dialog;

function open(href, alt) {
  if (!dialog) {
    dialog = document.createElement('dialog');
    dialog.className = 'lightbox';
    dialog.innerHTML = '<img alt="" />';
    // Any click closes: on the picture or on the backdrop around it.
    dialog.addEventListener('click', () => dialog.close());
    document.body.append(dialog);
  }
  const img = dialog.querySelector('img');
  img.src = href;
  img.alt = alt;
  dialog.showModal();
}

document.addEventListener('click', (e) => {
  const link = e.target.closest('a[data-lightbox]');
  if (!link || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey) return;
  e.preventDefault();
  open(link.href, link.querySelector('img')?.alt ?? '');
});
