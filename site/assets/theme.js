// Runs in <head> before first paint: apply a saved light/dark choice. No attribute = follow the system.
(function () { try { var t = localStorage.getItem("aqw-theme"); if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t); } catch (e) {} })();
