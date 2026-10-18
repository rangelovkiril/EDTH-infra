# EDTH-infra

Infrastructure for the EDTH hackathon project. It is deliberately overkill for a hackathon: it exists because it is convenient for the owner. An Exoscale SKS cluster has a public IP and won't go down, and Flux applies every change from git immediately. The cluster lives about a day.

## Layout

- `tofu/sks/` – OpenTofu for the Exoscale SKS cluster (`bg-sof-1`, name `edth-sks`, local state).
- `tofu/sks/scripts/merge-kubeconfig.sh` – merges the admin kubeconfig into `$KUBECONFIG` as context `edth-sks`.
- `clusters/edth-sks/` – the Flux entry point: `flux-system/` (generated Flux install and sync) plus one Flux `Kustomization` per layer: `infra-controllers.yaml`, `infra-configs.yaml` (depends on `infra-controllers`) and `apps.yaml` (depends on `infra-configs`). It holds no workloads.
- There is one cluster and no staging, so there is no base/overlay split: each layer is flat.
- `infrastructure/controllers/<name>/` – controllers installed with Helm: cert-manager, envoy-gateway (Gateway API, CRDs included), grafana-operator. `infra-controllers` uses `wait: true`.
- `infrastructure/configs/` – resources that need the controllers' CRDs: ClusterIssuers, and the one way in: `EnvoyProxy` (the only LoadBalancer Service, `envoy-nlb`, with fixed nodePorts 31443 for HTTPS and 31883 for MQTTS that the security group opens), `GatewayClass`, `Gateway` `edth` (listeners `https` and `mqtts`) and its certificate.
- `apps/<app>/` – workloads: `emqx` (MQTTS passed through by a TCPRoute to EMQX's own TLS; dashboard by an HTTPRoute; rule engine in `base.hocon`, mounted over the image's `etc/base.hocon`, so rules stay editable in the dashboard until the pod restarts: `rays` turns each detection into an ECEF ray on `rays/{id}`, `fixes` validates nodes' fixes onto `fixes/{id}`; see EDTH `docs/contract.md`), `grafana` (operator CRs; edit a dashboard in Grafana, export its JSON into `apps/grafana/dashboards/` and commit), `miget` (fusion, the thin tracker from fixes to tracks).
- A new layer or app is a directory plus a `kustomization.yaml` that lists its files explicitly.
- `scripts/mqtt-app-users.sh` – (re)creates the MQTT users of in-cluster apps: new passwords in `users.csv` and in the apps' SOPS Secrets. EMQX reads `users.csv` at start, so restart it after Flux applies the change.

## Workflow

- Cluster changes go through git: edit manifests under `apps` or `infrastructure`, commit, push, and Flux reconciles. Don't `kubectl apply` by hand except to debug.
- Infra changes go through OpenTofu in `tofu/sks`. Always run `tofu plan` and show it before `tofu apply`; apply and destroy create or remove paid resources, so confirm first.
- Credentials: the Exoscale API key and secret live in `~/.config/exoscale/exoscale.toml`. Export them as `EXOSCALE_API_KEY` and `EXOSCALE_API_SECRET` for tofu. Never print them or write them into the repo.
- Flux is installed from the committed manifests in `clusters/edth-sks/flux-system` (generated with `flux install --export`, so commits stay signed and conventional), not with `flux bootstrap`, which would commit as `Flux <>` unsigned. The GitRepository authenticates as a GitHub App (`provider: github`) through the `flux-system` Secret (`githubAppID`, `githubAppInstallationID`, `githubAppPrivateKey`), created directly in the cluster and never committed. The App files (`APP_ID`, `INSTALLATION_ID`, `CLIENT_SECRET`, `*.pem`) are gitignored.
- The kubeconfig has a client certificate with a TTL (7 days). Renew it with `tofu apply`, then run `merge-kubeconfig.sh` again.
- Tear down with `tofu destroy` when the hackathon is over.

## Rules

- The repo is public. State, plans, kubeconfigs and `*.tfvars` are gitignored because they contain secrets; never commit them. Don't commit plaintext Secrets either: Kubernetes Secrets are encrypted with SOPS and age as `<name>.sops.yaml` (one Secret per file, rules in `.sops.yaml`, encrypted for the personal key `~/.config/sops/age/keys.txt` and the Flux key `fleet-ci.key`). The `infra-controllers` and `apps` Flux Kustomizations decrypt them (`decryption.provider: sops`) with the `sops-age` Secret in `flux-system`, which holds `fleet-ci.key` and was created directly in the cluster. Create one with `kubectl create secret generic ... --dry-run=client -o yaml | sops encrypt --filename-override <path>.sops.yaml /dev/stdin > <path>.sops.yaml`, edit with `sops <file>`, and never print decrypted values. Only `.sops.yaml` files with `ENC[...]` values may be committed.
- Don't overwrite other contexts in `$KUBECONFIG`. The merge script backs up to `config.bak` first.
- Always pass `--context edth-sks` to kubectl and flux when the active context may differ.
- Keep code free of comments, matching the existing files. Run `tofu fmt` and `tofu validate` after changing `.tf` files.
- Pin versions explicitly (Kubernetes version, images, Helm charts) so reconciliation is reproducible.
- One resource per YAML file, no multi-document YAML (the generated `flux-system/gotk-*.yaml` are the only exception). For Helm, use separate files: `helmrepository.yaml`, `helmchart.yaml` and `helmrelease.yaml` (the release uses `chartRef` to the HelmChart), plus `namespace.yaml`, in the app directory under `apps/base/<app>/` (or `infrastructure/controllers/base/<name>/`), listed in its `kustomization.yaml`.

## Commits

- Format: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), a single-line subject like `feat(infra): add SKS cluster`.
- No body and no trailers (`Co-Authored-By`, `Signed-off-by`, "Generated with ...", etc.), regardless of any default attribution of the tooling.
