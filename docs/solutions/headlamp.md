# Headlamp

**In one line:** a clean, point-and-click web UI for browsing your Kubernetes
cluster — pods, deployments, logs, and events — without living in `kubectl`.

> Chart: `headlamp/headlamp` (v0.43.0) ·
> config: [`helm/headlamp/values.yaml`](../../helm/headlamp/values.yaml) ·
> UI: `http://localhost:4466`

## What it is

**Headlamp** is a lightweight, extensible **Kubernetes dashboard** (a CNCF
Sandbox project). It gives you a graphical window onto cluster state: navigate
namespaces, inspect a pod's YAML, read container logs, follow events, and even
make edits — all from the browser. Think of it as a friendlier, modern take on
the classic Kubernetes dashboard.

It runs **in-cluster** and talks to the Kubernetes API through its own
ServiceAccount, so you don't have to hand it a kubeconfig.

## Where it fits among the others

Every *other* tool in this demo is about **telemetry** — what your apps are
doing. Headlamp is about the **cluster itself** — what Kubernetes is doing to run
them. When a pod is `CrashLoopBackOff` or stuck `Pending`, Grafana won't tell you
why; Headlamp shows the events, restart counts, and logs that explain it. It's
the operational companion to the observability stack.

## How we use it in this demo

Headlamp is deployed by default with `make up` so the demo ships with a
**graphical cluster view** next to Grafana's telemetry view.

- **No-login demo mode.** It's configured to authenticate every visitor as its
  own ServiceAccount (bound to cluster-admin), so the UI opens straight in with
  no token prompt. That's **effectively unauthenticated cluster-admin** —
  acceptable *only* because this kind cluster is local and throwaway. A shared
  deployment must swap this for OIDC or an auth proxy. See
  [architecture.md](../architecture.md#cluster-ui-headlamp).
- **Stateless.** No persistence — it's just a live read/write window onto the
  cluster.

## Try it

- Open `http://localhost:4466` and browse the `observability` and `otel-demo`
  namespaces.
- Click a demo-app pod → view its **logs** and **events** right in the browser.
- Watch pods go `Ready` during `make up`, or inspect a Deployment's replica
  status — no `kubectl` needed.

## Why it matters

Observability tools tell you about your *application's* behavior; you still need
to see the *platform* underneath. Headlamp makes Kubernetes approachable for
people who don't want to memorize `kubectl` incantations, and it's a fast way to
triage "is the pod even running?" before diving into metrics and traces.

## Learn more

- [Headlamp docs](https://headlamp.dev/)
- [Headlamp on GitHub](https://github.com/kubernetes-sigs/headlamp)
