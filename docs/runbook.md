# Runbook — platform-supply-chain

Operação do dia 2 em pt-BR. Este pilar **não roda no cluster**: não há Application do ArgoCD, namespace, pod ou
NetworkPolicy para investigar. Tudo acontece em GitHub Actions e no GHCR.

## Mapa rápido

| O quê | Onde |
|---|---|
| Pipeline | `.github/workflows/reusable-container.yml` (build·sbom·scan·sign·attest + job `verify`) |
| Consumidores | qualquer repo com `uses: slackerwx/platform-supply-chain/.github/workflows/reusable-container.yml@v1` |
| Artefatos | `ghcr.io/slackerwx/<nome>` + tags `sha256-….sig` (assinatura) e `sha256-….att` (attestation) |
| Log público | Rekor — `rekor-cli search --sha <digest>` |
| Verificação humana | `./scripts/verify-image.sh <ref>` |
| Contrato com o cluster | ClusterPolicy `verify-images-slackerwx` em `platform-policies` |

## Comandos do dia a dia

```bash
# Última execução deste repo
gh run list --repo slackerwx/platform-supply-chain --limit 5
gh run watch <id> --repo slackerwx/platform-supply-chain --exit-status

# Verificar uma imagem publicada (pacote privado → precisa de PAT com read:packages)
GHCR_TOKEN=<PAT> ./scripts/verify-image.sh ghcr.io/slackerwx/platform-supply-chain-hello:<sha7>

# Ver o SBOM inteiro. O cosign v3 devolve Sigstore bundles: o DSSE fica em .dsseEnvelope, e vêm três
# attestations (SPDX, cosign sign, SLSA provenance) — daí o select pelo predicateType.
cosign download attestation ghcr.io/slackerwx/<img>@sha256:<digest> \
  | jq -r '.dsseEnvelope.payload // .payload' \
  | while read -r p; do echo "$p" | openssl base64 -d -A; echo; done \
  | jq -r 'select(.predicateType | test("spdx"; "i")) | .predicate.packages[] | "\(.name) \(.versionInfo)"'

# Ver a provenance
gh attestation verify oci://ghcr.io/slackerwx/<img>@sha256:<digest> --owner slackerwx \
  --format json | jq '.[0].verificationResult.statement.predicate.buildDefinition'

# Descobrir quais objetos existem ao lado da imagem
cosign tree ghcr.io/slackerwx/<img>@sha256:<digest>
```

## Repontar a tag `v1`

Os consumidores fixam `@v1`. Depois de mudar qualquer reusable workflow e ter o CI verde na `main`:

```bash
git tag -f v1 -m "reusable supply-chain workflows v1"
git push -f origin v1
```

Verifique um consumidor logo depois — `gh workflow run ci.yml --repo slackerwx/platform-finops` — porque um `v1`
quebrado quebra **todos** os repositórios de uma vez. Essa é a desvantagem aceita da tag móvel; quem quiser o
contrário fixa um SHA de commit.

> ⚠️ **Imagem construída a partir da tag não é admissível no cluster.** Empurrar `v1` dispara o `ci.yml`
> (`on.push.tags: ["v*"]`), que publica e assina com identidade `…@refs/tags/v1`. O job `verify` aceita — o regexp
> dele cobre `refs/heads/main` **e** `refs/tags/v*`. O Kyverno **não**: o `verify-images-slackerwx` exige
> `@refs/heads/main$`. É de propósito, para que só o que passou pela `main` chegue no cluster; a assimetria só
> importa se alguém tentar fazer deploy de uma imagem `:1` ou `:1.0.0` em vez da `:<sha7>`. Sintoma nesse caso:
> `image is not signed` no admission, com a assinatura existindo no registry.

## Falhas comuns

### `Error: no matching signatures`

A assinatura não existe para **aquele digest**. Causas, em ordem de probabilidade:

1. A imagem foi construída num pull request (`push: false`) — PR nunca assina, por design.
2. A imagem foi publicada na mão, fora do workflow (ver exercício 3 do `LEARNING.md`).
3. A tag foi movida para outro manifest depois da assinatura → verifique sempre por digest, não por tag.
4. O regexp de identidade da verificação está mais estrito do que a identidade real. Compare os três lugares onde
   ele aparece: job `verify`, `scripts/verify-image.sh` e a ClusterPolicy do Kyverno.

### `UNAUTHORIZED` / `denied` no `cosign verify`

Pacote GHCR privado sem credencial. Exporte `GHCR_TOKEN` (PAT com `read:packages`) antes de rodar o script, ou
`cosign login ghcr.io -u slackerwx --password-stdin`.

### O job `container` falha em "Fail on vulnerabilities above the gate"

O Grype achou CVE **com correção disponível** na severidade do gate ou acima (`only_fixed: true` é o padrão).
Triagem:

1. Abra o **job summary** da execução: o relatório completo (todas as severidades, com e sem correção) está lá, e
   também no artefato `vulnerabilities-<image_name>`. Se o repo tiver GHAS, o SARIF está em **Security → Code
   scanning**.
2. Se veio do seu código: suba a dependência e refaça o `uv lock`.
3. Se veio da imagem base: suba o patch (`python:3.12.x-slim` mais nova) no `Dockerfile`.
4. Se não há correção disponível, o gate padrão **não** deveria ter barrado — confira se alguém passou
   `only_fixed: false`. Não afrouxe `fail_on_severity` como atalho: documente no PR e, quando VEX sair do backlog,
   suprima a CVE específica.

Para reproduzir a triagem na sua máquina, sem Docker, a partir do SBOM que o próprio run publicou:

```bash
gh run download <id> --repo slackerwx/<repo> -n sbom-<image_name>
grype sbom:sbom.spdx.json -o table              # tudo
grype sbom:sbom.spdx.json -o table --only-fixed # o que o gate enxerga
```

### O upload do SARIF falha

`Advanced Security must be enabled for this repository` — acontece em repositório **privado** sem GHAS, ou seja,
nos consumidores, não aqui (este repo é público e tem code scanning de graça). O step já é
`continue-on-error: true`; o build não quebra e o gate continua funcionando. É esperado, não é incidente.

### `Failed to persist attestation: Feature not available for user-owned private repositories`

O `actions/attest-build-provenance` não funciona em repo privado de conta pessoal — só em repo público ou em plano
Team/Enterprise. Foi por isso que **este** repositório é público.

Um consumidor privado passa **`attest_provenance: false`**:

```yaml
    with:
      image_name: platform-sre-agent
      push: ${{ github.event_name != 'pull_request' }}
      attest_provenance: false      # repo privado de conta pessoal
```

Ele continua assinado e com SBOM assinado; perde só a provenance, e o job avisa no summary. As alternativas para
recuperar a terceira alegação são tornar o repo público ou movê-lo para uma org com plano Team.

### O job `verify` falha mas o `build` passou

Exatamente o caso que o job existe para pegar. Ordem de investigação:

1. `cosign tree <ref>` — a `.sig` está lá? a `.att`? Se falta a attestation, alguém rodou `cosign clean` ou o step
   de attest foi pulado.
2. A provenance está no registry? `gh attestation verify` falha se o `attest-build-provenance` não rodou com
   `push-to-registry: true`.
3. O chamador esqueceu `attestations: write` ou `id-token: write` nas permissões? O `build` passa e o `verify`
   quebra depois.

**Recuperação:** reexecute o workflow na `main` (`gh run rerun <id>`). Os steps de sign/attest são idempotentes
sobre o mesmo digest.

### Um consumidor quebrou depois de um bump do Dependabot

Reverta o merge do bump, repontar `v1` para o commit anterior e reabra o PR do Dependabot com a correção. Um bump de
SHA de action é a mudança de maior alcance neste repositório justamente porque `v1` é móvel.

## Recuperação: "preciso reassinar uma imagem antiga"

Não reassine imagem antiga na mão — isso produz uma assinatura cuja identidade é a sua conta, não a workflow, e o
Kyverno vai recusar assim mesmo. O caminho correto é **rebuildar a partir do commit**:

```bash
gh workflow run ci.yml --repo slackerwx/<repo> --ref main
```

Se o objetivo é assinar um commit antigo especificamente, faça um branch a partir dele, abra PR e faça merge — a
identidade precisa ser `@refs/heads/main` para o cluster aceitar.

## Antes de ligar o Enforce no Kyverno

Checklist na ordem, porque inverter derruba workloads em produção:

1. `v1` existe e o CI deste repo está verde.
2. `platform-finops` já migrou para o reusable workflow e a imagem em execução é assinada
   (`./scripts/verify-image.sh` na tag que está rodando).
3. O namespace `kyverno` tem o `ghcr-secret` — sem credencial, o Kyverno não consegue buscar a assinatura de um
   pacote privado e falha *fechado*.
4. Só então aponte o Application `policies` para `overlays/enforce`.

Se algo der errado depois do Enforce: volte o Application para `deploy/policies/base` (Audit). É um `git revert` no
`proxmox-infrastructure`, e o ArgoCD reconcilia.
