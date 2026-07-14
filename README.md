# synapse stack module

- Module id: `synapse`
- Module repo: `synapse-stack-module`
- Source repo: none declared
- Lifecycle: `active`

## Owned overlays
- `stack.runtime.yaml`
- `stack.config/synapse`
- `stack.containers/synapse`

## Dependencies
- `stack-foundation`

## Validation

```sh
./tests/validate.sh
```

## Lifecycle

`active` modules are expected to keep `stack.module.json`, owned overlays, and `tests/validate.sh` in sync.
