// Theme controls shared by the home page and the generated pages.
// #themeToggle (nav button) cycles auto -> light -> dark -> auto; #themeSelect (footer) sets a mode directly.
// The choice is stored in localStorage "aqw-theme"; theme.js applies it in <head> before first paint.
// Labels come from window.I18N when the page has it (home page), otherwise from data-l-* attributes
// on the button (generated pages write them in the page's language).
(function () {
  "use strict";
  var KEY = "aqw-theme", MODES = ["auto", "light", "dark"];
  var root = document.documentElement;

  function get() {
    try { var v = localStorage.getItem(KEY); return v === "light" || v === "dark" ? v : "auto"; } catch (e) { return "auto"; }
  }
  function label(key) {
    var lang = (root.getAttribute("lang") || "en").indexOf("zh") === 0 ? "zh" : "en";
    var dict = window.I18N && window.I18N[lang];
    if (dict && dict["theme." + key]) return dict["theme." + key];
    var btn = document.getElementById("themeToggle");
    return (btn && btn.getAttribute("data-l-" + key)) || key.charAt(0).toUpperCase() + key.slice(1);
  }
  function refresh() {
    var mode = get();
    var btn = document.getElementById("themeToggle");
    if (btn) {
      var text = label("label") + ": " + label(mode);
      btn.setAttribute("data-mode", mode);
      btn.setAttribute("aria-label", text);
      btn.setAttribute("title", text);
    }
    var sel = document.getElementById("themeSelect");
    if (sel) {
      for (var i = 0; i < sel.options.length; i++) sel.options[i].textContent = label(sel.options[i].value);
      sel.value = mode;
    }
    var selLabel = document.getElementById("themeSelectLabel");
    if (selLabel) selLabel.textContent = label("label");
  }
  function set(mode) {
    if (MODES.indexOf(mode) < 0) mode = "auto";
    try { if (mode === "auto") localStorage.removeItem(KEY); else localStorage.setItem(KEY, mode); } catch (e) { /* storage blocked: this page only */ }
    if (mode === "auto") root.removeAttribute("data-theme"); else root.setAttribute("data-theme", mode);
    refresh();
  }

  var btn = document.getElementById("themeToggle");
  if (btn) btn.addEventListener("click", function () { set(MODES[(MODES.indexOf(get()) + 1) % MODES.length]); });
  var sel = document.getElementById("themeSelect");
  if (sel) sel.addEventListener("change", function () { set(sel.value); });
  // Another tab changed the theme.
  window.addEventListener("storage", function (e) { if (e.key === KEY) set(get()); });
  refresh();

  window.AQW_THEME = { get: get, set: set, refresh: refresh };
})();
