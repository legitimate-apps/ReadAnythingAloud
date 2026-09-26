// Safari runs this in the shared page before handing it to the extension, so the app receives the page exactly as
// the user sees it (logged in, past consent walls) instead of re-fetching it anonymously.
var ExtensionPreprocessingJS = {
    run: function (args) {
        var html = "";
        try { html = document.documentElement.outerHTML; } catch (e) {}
        if (html.length > 8000000) { html = ""; }
        args.completionFunction({ url: document.URL, title: document.title, html: html });
    },
    finalize: function () {}
};
