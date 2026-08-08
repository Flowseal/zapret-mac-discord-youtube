### Оригинал -  [zapret](https://github.com/bol-van/zapret)
---

# Форк zapret под MacOS

Использует `nfqws` через `utun` и BPF. Управление через трей.  
**Universal, MacOS 14+**

Стратегии перенесены как есть из [сборки Windows](https://github.com/Flowseal/zapret-discord-youtube/). GameFilter вырезан. В текущей версии стратегии захардкожены, переключение IPSet/изменение списков требует перезапуска.

## Списки

При первом запуске меню создаёт папку `~/Library/Application Support/ZapretMac/lists`. Исходные `list-general.txt`, `list-google.txt`, `list-exclude.txt`, `ipset-exclude.txt` и загруженный `ipset-all.txt` взяты из из [сборки Windows](https://github.com/Flowseal/zapret-discord-youtube/).

Пользовательские домены добавляются в `list-general-user.txt`. Поддомены учитываются автоматически. Исключения доменов добавляются в `list-exclude-user.txt`, исключения IP и подсетей — в `ipset-exclude-user.txt`.

Режимы IPSet:

- `none` не применяет дополнительный обход по IP;
- `loaded` использует `ipset-all.txt`;
- `any` применяет IP-профили ко всем IPv4-адресам, кроме исключений.

После редактирования списка повторно выберите текущую стратегию или режим IPSet, чтобы перезапустить работающий сервис с новым содержимым.

## Сборка

Локально на macOS:

```bash
./macos/build.sh
```

`dist/ZapretMac-macOS-universal.zip`.

GitHub Actions workflow `.github/workflows/macos.yml` собирает тот же universal-архив

### Прочее

Пункт "Выход" закрывает только приложение строки меню. Запущенный сервис продолжает работать до выбора "Остановить".

#### Принудительная остановка

```bash
sudo "/Library/Application Support/ZapretMac/stop.sh"
```