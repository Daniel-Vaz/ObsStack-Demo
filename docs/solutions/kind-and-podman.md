# Kind & Podman

**In one line:** the two tools that let this whole stack run on your laptop —
**Podman** runs containers, and **Kind** turns those containers into a real
throwaway Kubernetes cluster.

> config: [`kind/cluster.yaml`](../../kind/cluster.yaml) ·
> the Makefile exports `KIND_EXPERIMENTAL_PROVIDER=podman` so they work together

These two aren't part of the observability stack — they're the **platform**
everything else runs *on*. Understanding them makes the demo's setup and its
quirks (like how the UIs get onto `localhost`) make sense.

## Podman — the container runtime

**Podman** builds and runs containers, much like Docker, and is deliberately
**CLI-compatible** with it (`podman run …` mirrors `docker run …`). Two
differences matter here:

- **Daemonless & rootless.** Docker runs a privileged background daemon; Podman
  runs containers as ordinary child processes, and can run them **without root**.
  That's more secure and needs no always-on service — a good fit for a laptop and
  for locked-down corporate machines.
- **Drop-in replacement.** Because it matches Docker's interface, tools that
  expect Docker can usually be pointed at Podman with a flag or environment
  variable — which is exactly what we do with Kind below.

In this demo Podman is what actually builds the demo-app image and runs the
container(s) that *become* the Kubernetes nodes.

## Kind — Kubernetes IN Docker

**Kind** ("**K**ubernetes **in D**ocker") runs a **full Kubernetes cluster inside
containers.** Each Kubernetes "node" is just a container running the Kubernetes
components. That means you get a genuine, conformant cluster — same API, same
`kubectl`, same Helm charts as production — that you can create in a minute and
throw away just as fast.

- **Real, but disposable.** Perfect for demos, CI, and local development: `make
  up` creates it, `make down` deletes it, nothing lingers.
- **Config as YAML.** [`kind/cluster.yaml`](../../kind/cluster.yaml) declares a
  single-node cluster and, importantly, its **port mappings**.
- **Runs on Podman.** Despite the name, Kind isn't tied to Docker — this demo
  sets `KIND_EXPERIMENTAL_PROVIDER=podman` so Kind builds its node containers with
  Podman.

## How they combine here

```
  Podman  ─── runs the container(s) that ───▶  Kind node(s)  ─── run ───▶  Kubernetes
                                                                            (pods: Grafana,
                                                                             Alloy, Mimir, …)
```

Podman provides the containers; Kind arranges them into a Kubernetes cluster; the
whole observability stack is then `helm install`-ed into that cluster.

### The one quirk worth knowing: getting UIs onto localhost

A normal cluster would expose web UIs through a cloud load balancer — which
doesn't exist on a laptop. So Kind uses **`extraPortMappings`** to publish node
ports straight onto the host, and each UI is a `NodePort` service on a pinned
port. That's why Grafana lands on `http://localhost:3000`, Headlamp on `:4466`,
and so on — no `kubectl port-forward` needed.

Because those mappings are fixed when the cluster is created, **changing a port
requires `make down && make up`.** Full detail in
[architecture.md](../architecture.md#exposing-the-uis-nodeport--extraportmappings).

## Why it matters

Together, Kind and Podman make this entire stack **reproducible on any laptop** —
no cloud account, no cost, no shared environment to break. You get a real
Kubernetes cluster to learn on, and when you're done, one command removes every
trace of it.

## Learn more

- [Kind docs](https://kind.sigs.k8s.io/)
- [Podman docs](https://podman.io/)
