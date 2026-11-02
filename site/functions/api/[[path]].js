// Pages Function: the anonymous collector served at /api/* on the same domain as the site.
import worker from "../../../collector/worker.js";

export const onRequest = (context) => worker.fetch(context.request, context.env);
