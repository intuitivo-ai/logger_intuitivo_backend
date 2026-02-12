# LoggerIntuitivoBackend

Backend de [Elixir Logger](https://hexdocs.pm/logger/Logger.html) que envía los logs a través del Socket del firmware (por ejemplo hacia CloudWatch/AWS). Incluye modo verbose, buffering con límite de tamaño, throttle para mensajes repetidos y filtros configurables.

## Características

- **Un solo backend**: Un único backend con nivel mínimo (p. ej. `:info`) para evitar triplicar errores o duplicar warnings.
- **Modo verbose**: Si está activo, cada log se envía de inmediato; si no, se acumulan en buffers y se envían en bloques.
- **Buffers**: Dos buffers (logs de aplicación In2Firmware vs sistema); se hace flush al alcanzar `buffer_size` entradas, con límite `max_message_bytes` para no superar límites de CloudWatch.
- **Throttle**: Evita inundar el socket con el mismo mensaje repetido (p. ej. errores SQUASHFS); tras N repeticiones en una ventana de tiempo se envía un resumen.
- **Filtros**: Exclusión de mensajes que contengan ciertas cadenas (p. ej. "SQUASHFS error"); envío inmediato para otras (p. ej. health check del socket).

## Dependencia

En tu proyecto (p. ej. firmware-nerves):

**Uso local (mismo nivel que el repo del firmware):**

```elixir
def deps do
  [
    {:logger_intuitivo_backend, "~> 1.0",
     path: "../logger_logstash_backend",
     targets: @all_targets}
  ]
end
```

**Cuando esté en un repositorio:**

```elixir
def deps do
  [
    {:logger_intuitivo_backend, "~> 1.0",
     git: "https://github.com/intuitivo-ai/logger_intuitivo_backend.git",
     branch: "main",
     targets: @all_targets}
  ]
end
```

Luego ejecuta `mix deps.get`.

## Opciones de configuración

| Opción | Por defecto | Descripción |
|--------|-------------|-------------|
| `socket_module` | *(requerido)* | Módulo que implementa `send_log({msg, id})` y `send_system(msg)` (p. ej. `In2Firmware.Services.Communications.Socket`). |
| `level` | `:debug` | Nivel mínimo de log (recomendado `:info` para recibir info, warning y error sin duplicados). |
| `format` | `"$date $time [$level] $metadata $message\n"` | Formato del mensaje (ver [Logger.Formatter](https://hexdocs.pm/logger/Logger.Formatter.html)). |
| `metadata` | `[]` | Metadatos a incluir (p. ej. `[:mac_addr, :transaction_id, :app]`). |
| `verbose_file` | `"/root/verbose.txt"` | Archivo donde se lee/escribe el modo verbose (`"true"` / `"false"`). |
| `buffer_size` | `20` | Número de líneas en buffer antes de hacer flush. |
| `max_message_bytes` | `256 * 1024` | Tamaño máximo del mensaje combinado (para CloudWatch). |
| `throttle_enabled` | `true` | Activa el throttle de mensajes repetidos. |
| `throttle_window_sec` | `60` | Ventana en segundos para considerar repeticiones. |
| `throttle_max_repeats` | `3` | Máximo de envíos del mismo mensaje en la ventana; el resto se resume. |
| `exclude_message_containing` | `["SQUASHFS error"]` | Lista de cadenas: si el mensaje las contiene, no se envía. |
| `immediate_send_containing` | `["MAIN_SERVICES_CONNECTIONS_SOCKET_HEALTH"]` | Lista de cadenas: si el mensaje las contiene, se envía de inmediato (sin buffer ni throttle). |

## Ejemplo de configuración (firmware)

En `config/config.exs`:

```elixir
config :logger,
  backends: [
    {LoggerIntuitivoBackend, :socket},
    RingLogger
  ]

config :logger, :socket,
  format: "$date $time [$level] $metadata $message\n",
  metadata: [:mac_addr, :transaction_id, :app],
  level: :info,
  socket_module: In2Firmware.Services.Communications.Socket
```

Para activar/desactivar modo verbose en runtime (p. ej. desde el manager de control):

```elixir
# Verbose on: cada log se envía de inmediato
Logger.configure_backend({LoggerIntuitivoBackend, :socket}, verbose: true)

# Verbose off: se acumulan en buffers
Logger.configure_backend({LoggerIntuitivoBackend, :socket}, verbose: false)
```

## Contrato del Socket

El módulo configurado en `socket_module` debe exportar:

- `send_log({mensaje_binario, id})` — para logs de la aplicación (mensajes que contienen "In2Firmware").
- `send_system(mensaje_binario)` — para logs del sistema (resto).

El backend formatea cada log como texto (no JSON) usando el `format` configurado.

## Tests

```bash
mix test
```

Los tests usan un mock de socket (`LoggerIntuitivoBackend.TestSocket`) que escribe los mensajes en un Agent para comprobar el comportamiento sin depender del firmware.

## Licencia

Apache 2.0. Ver [LICENSE](LICENSE).
