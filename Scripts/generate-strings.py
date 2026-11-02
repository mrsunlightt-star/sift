#!/usr/bin/env python3
"""Generate Shared/Localization/Localizable.xcstrings from one reviewable table.

The string catalog is the single source of user-visible text (spec §11.5). Keeping
the table here means a reviewer can read every language side by side, and a
missing translation is caught by the build script below rather than discovered by
a user.

The catalogue is four tables merged: `STRINGS` holds the eight v1 languages,
`STRINGS_EXPANSION` the six added with the 2.0 redesign, `STRINGS_EXPANSION_2`
the first international expansion (Lao plus the right-to-left Arabic, Hebrew and
Persian) and `STRINGS_EXPANSION_3` the remaining store languages, appended in
that order. All four must cover exactly the same keys.

Usage:
    python3 Scripts/generate-strings.py            # writes the catalog
    python3 Scripts/generate-strings.py --check     # verifies it is current
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "Shared" / "Localization" / "Localizable.xcstrings"
KEYS = REPO_ROOT / "Shared" / "Localization" / "LocalizationKey.swift"

# Source language. English is the fallback for every missing translation.
SOURCE = "en"

# Languages shipped in v1 (spec §11.5).
LANGUAGES = ["en", "zh-hans", "ko", "ru", "es", "ja", "fr", "de"]

# key: [en, zh-Hans, ko, ru, es, ja, fr, de] — the expansion languages
# (EXPANSION_LANGUAGES below) are appended to every row by the merge after
# the STRINGS_EXPANSION table.
STRINGS: dict[str, list[str]] = {
    # --- Application shell -------------------------------------------------
    "nav.dashboard": ["Overview", "总览", "개요", "Обзор", "Resumen", "概要", "Aperçu", "Übersicht"],
    "nav.smartScan": ["Smart Scan", "智能扫描", "스마트 스캔", "Умное сканирование", "Análisis inteligente", "スマートスキャン", "Analyse intelligente", "Intelligenter Scan"],
    "nav.junkCleanup": ["Junk Cleanup", "垃圾清理", "정리 정돈", "Очистка мусора", "Limpieza", "ジャンククリーニング", "Nettoyage", "Müll bereinigen"],
    "nav.uninstaller": ["Uninstaller", "软件卸载", "앱 제거", "Удаление программ", "Desinstalador", "アンインストーラ", "Désinstallation", "Deinstallation"],
    "nav.fileCleanup": ["File Cleanup", "文件清理", "파일 정리", "Очистка файлов", "Limpieza de archivos", "ファイルの整理", "Nettoyage de fichiers", "Dateien bereinigen"],
    "nav.storageAnalysis": ["Storage", "存储", "저장 공간 분석", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
    "nav.settings": ["Settings", "设置", "설정", "Настройки", "Ajustes", "設定", "Réglages", "Einstellungen"],
    "nav.privacy": ["Privacy", "隐私说明", "개인정보", "Конфиденциальность", "Privacidad", "プライバシー", "Confidentialité", "Datenschutz"],

    # --- Dashboard ---------------------------------------------------------
    "dashboard.scanCard.title": [
        "Find what can be safely cleaned",
        "找出可以安全清理的内容",
        "안전하게 정리할 항목 찾기",
        "Найдите то, что можно безопасно очистить",
        "Encuentra lo que se puede limpiar con seguridad",
        "安全に削除できる項目を探す",
        "Trouvez ce qui peut être nettoyé sans risque",
        "Finden, was sicher bereinigt werden kann",
    ],
    "dashboard.scanCard.subtitle": [
        "Caches, logs, installers and leftover files. Every item shows its source and purpose before removal.",
        "扫描缓存、日志、安装包和残留文件。所有项目都会在删除前展示来源和用途。",
        "캐시, 로그, 설치 파일 및 잔여 파일을 검사합니다. 모든 항목은 삭제 전에 출처와 용도를 보여줍니다.",
        "Кэши, логи, установщики и остатки файлов. Каждый элемент показывает источник и назначение до удаления.",
        "Cachés, registros, instaladores y archivos residuales. Cada elemento muestra su origen y propósito antes de eliminarse.",
        "キャッシュ、ログ、インストーラ、残留ファイルを対象にします。削除前に由来と用途を表示します。",
        "Caches, journaux, installateurs et fichiers résiduels. Chaque élément indique son origine et son utilité avant suppression.",
        "Caches, Protokolle, Installer und Reste. Jeder Eintrag zeigt vor dem Löschen Quelle und Zweck.",
    ],
    "dashboard.startScan": ["Start scan", "开始扫描", "검사 시작", "Начать сканирование", "Iniciar análisis", "スキャン開始", "Lancer l’analyse", "Scan starten"],
    "dashboard.lastScan": ["Last scan: %@", "上次扫描：%@", "마지막 검사: %@", "Последнее сканирование: %@", "Último análisis: %@", "前回のスキャン: %@", "Dernière analyse : %@", "Letzter Scan: %@"],
    "dashboard.neverScanned": ["Not scanned yet", "尚未扫描", "아직 검사하지 않음", "Ещё не сканировалось", "Aún no analizado", "未スキャン", "Pas encore analysé", "Noch nicht gescannt"],
    "dashboard.diskUsed": ["Disk used", "磁盘已使用", "디스크 사용량", "Диск занят", "Disco usado", "ディスク使用量", "Disque utilisé", "Belegt"],
    "dashboard.diskFree": ["%@ free", "%@ 可用", "%@ 사용 가능", "%@ свободно", "%@ libre", "空き %@", "%@ libres", "%@ frei"],
    "dashboard.suggestedCleanup": ["Suggested first", "建议优先处理", "우선 정리 권장", "Сначала обработать", "Sugerido primero", "先に処理する項目", "À traiter en priorité", "Zuerst bereinigen"],
    "dashboard.recentActivity": ["Recent activity", "最近活动", "최근 활동", "Недавние действия", "Actividad reciente", "最近のアクティビティ", "Activité récente", "Letzte Aktivitäten"],
    "dashboard.cleanupCompleted": ["Cleanup completed", "清理完成", "정리 완료", "Очистка завершена", "Limpieza completada", "クリーンアップ完了", "Nettoyage terminé", "Bereinigung abgeschlossen"],
    "dashboard.scanCompleted": ["Scan completed", "扫描完成", "검사 완료", "Сканирование завершено", "Análisis completado", "スキャン完了", "Analyse terminée", "Scan abgeschlossen"],
    "dashboard.now": ["Now", "现在", "현재", "Сейчас", "Ahora", "現在", "Maintenant", "Jetzt"],
    "dashboard.lookSuggestions": ["Review suggestions", "查看建议", "제안 보기", "Посмотреть предложения", "Ver sugerencias", "提案を見る", "Voir les suggestions", "Vorschläge ansehen"],

    # --- Scan --------------------------------------------------------------
    "scan.phase.idle": ["Waiting to scan", "等待扫描", "검사 대기 중", "Ожидание сканирования", "Esperando análisis", "スキャン待機中", "En attente", "Wartet auf Scan"],
    "scan.phase.preparing": ["Preparing folders and permissions", "准备目录和权限", "폴더와 권한 준비 중", "Подготовка папок и разрешений", "Preparando carpetas y permisos", "フォルダと権限を準備しています", "Préparation des dossiers et autorisations", "Ordner und Berechtigungen werden vorbereitet"],
    "scan.phase.scanning": ["Scanning", "扫描中", "검사 중", "Сканирование", "Analizando", "スキャン中", "Analyse en cours", "Wird gescannt"],
    "scan.phase.indexing": ["Measuring sizes and grouping duplicates", "计算大小并分组重复文件", "크기 계산 및 중복 그룹화", "Подсчёт размеров и группировка дубликатов", "Midiendo tamaños y agrupando duplicados", "サイズを計算し重複を整理しています", "Calcul des tailles et regroupement des doublons", "Größen werden gemessen, Duplikate gruppiert"],
    "scan.phase.ready": ["Scan complete", "扫描完成", "검사 완료", "Сканирование завершено", "Análisis completado", "スキャン完了", "Analyse terminée", "Scan abgeschlossen"],
    "scan.phase.cancelled": ["Scan cancelled", "扫描已取消", "검사 취소됨", "Сканирование отменено", "Análisis cancelado", "スキャンを中止しました", "Analyse annulée", "Scan abgebrochen"],
    "scan.phase.partial": ["Some locations could not be read", "部分位置无法访问", "일부 위치를 읽을 수 없습니다", "Некоторые места недоступны", "Algunas ubicaciones no se pudieron leer", "一部の場所を読み取れませんでした", "Certains emplacements sont illisibles", "Einige Orte konnten nicht gelesen werden"],
    "scan.phase.failed": ["Scan failed", "扫描失败", "검사 실패", "Сканирование не удалось", "El análisis falló", "スキャンに失敗しました", "Échec de l’analyse", "Scan fehlgeschlagen"],
    "scan.currentItem": ["Currently checking: %@", "正在检查：%@", "확인 중: %@", "Проверяется: %@", "Comprobando: %@", "確認中: %@", "Vérification : %@", "Wird geprüft: %@"],
    "scan.cancel": ["Cancel scan", "取消扫描", "검사 취소", "Отменить сканирование", "Cancelar análisis", "スキャンを中止", "Annuler l’analyse", "Scan abbrechen"],
    "scan.results": ["Results", "扫描结果", "검사 결과", "Результаты", "Resultados", "結果", "Résultats", "Ergebnisse"],
    "scan.selectAll": ["Select all", "全选", "전체 선택", "Выбрать всё", "Seleccionar todo", "すべて選択", "Tout sélectionner", "Alle auswählen"],
    "scan.deselectAll": ["Deselect all", "取消全选", "선택 해제", "Снять выбор", "Deselect all", "すべて解除", "Tout désélectionner", "Auswahl aufheben"],
    # The list is paged, so "select all" can only mean what the model holds. The
    # count is in the label rather than the ARIA text alone: the affordance is
    # what sets the expectation of how much will be selected.
    "scan.selectAllShown": ["Select all shown (%d)", "全选已显示（%d 项）", "표시된 항목 모두 선택(%d)", "Выбрать все показанные (%d)", "Seleccionar los mostrados (%d)", "表示中の %d 件をすべて選択", "Tout sélectionner parmi les %d affichés", "Alle %d angezeigten auswählen"],
    "scan.nothingFound": ["Nothing to clean up", "没有可清理项目", "정리할 항목이 없습니다", "Нечего очищать", "Nada que limpiar", "削除する項目はありません", "Rien à nettoyer", "Nichts zu bereinigen"],
    "scan.nothingFoundDetail": [
        "Sift found no caches, logs, installers or leftovers worth removing.",
        "Sift 没有发现值得清理的缓存、日志、安装包或残留。",
        "Sift가 정리할 만한 캐시, 로그, 설치 파일, 잔여 파일을 찾지 못했습니다.",
        "Sift не нашёл кэшей, журналов, установщиков или остатков, которые стоит удалить.",
        "Sift no encontró cachés, registros, instaladores ni restos que valga la pena eliminar.",
        "Sift は削除する価値のあるキャッシュ、ログ、インストーラ、残留ファイルを見つけませんでした。",
        "Sift n’a trouvé aucun cache, journal, installateur ou résidu qui vaille d’être supprimé.",
        "Sift hat keine Caches, Protokolle, Installer oder Reste gefunden, die sich zu entfernen lohnen.",
    ],
    "scan.partialNotice": ["%d locations were skipped", "%d 个位置已被跳过", "%d개 위치를 건너뛰었습니다", "Пропущено мест: %d", "%d ubicaciones omitidas", "%d 箇所をスキップしました", "%d emplacements ignorés", "%d Orte übersprungen"],
    "scan.openSystemSettings": ["Open System Settings", "打开系统设置", "시스템 설정 열기", "Открыть Системные настройки", "Abrir Ajustes del Sistema", "システム設定を開く", "Ouvrir les Réglages Système", "Systemeinstellungen öffnen"],
    "scan.skippedReason.permissionDenied": [
        "Sift needs extra permission for this location.",
        "这个位置需要额外权限。",
        "이 위치에는 추가 권한이 필요합니다.",
        "Для этого места нужны дополнительные разрешения.",
        "Esta ubicación necesita permiso adicional.",
        "この場所には追加の権限が必要です。",
        "Cet emplacement nécessite une autorisation supplémentaire.",
        "Für diesen Ort ist eine zusätzliche Berechtigung nötig.",
    ],
    "scan.skippedReason.protectedLocation": [
        "Sift never touches this location, to protect your files.",
        "为保护你的文件，Sift 不会处理此位置。",
        "파일 보호를 위해 이 위치는 처리하지 않습니다.",
        "Sift не трогает это место, чтобы защитить ваши файлы.",
        "Sift no toca esta ubicación para proteger tus archivos.",
        "ファイルを保護するため、この場所は処理しません。",
        "Sift ne touche pas à cet emplacement pour protéger vos fichiers.",
        "Sift lässt diesen Ort zum Schutz Ihrer Dateien unberührt.",
    ],
    "scan.skippedReason.fileNotFound": [
        "The item disappeared during the scan, so it was skipped.",
        "项目在扫描过程中被移除，已跳过。",
        "검사 중 항목이 사라져 건너뛰었습니다.",
        "Элемент исчез во время сканирования и был пропущен.",
        "El elemento desapareció durante el análisis, se omitió.",
        "スキャン中に項目が消えたためスキップしました。",
        "L’élément a disparu pendant l’analyse, il a été ignoré.",
        "Der Eintrag verschwand während des Scans und wurde übersprungen.",
    ],
    "scan.skippedReason.partialFailure": [
        "Part of this location could not be read.",
        "此位置的一部分无法读取。",
        "이 위치의 일부를 읽을 수 없습니다.",
        "Часть этого места не удалось прочитать.",
        "Parte de esta ubicación no se pudo leer.",
        "この場所の一部を読み取れませんでした。",
        "Une partie de cet emplacement n’a pas pu être lue.",
        "Ein Teil dieses Ortes konnte nicht gelesen werden.",
    ],
    "scan.skippedReason.timedOut": [
        "This directory stopped responding, so Sift skipped it.",
        "该目录长时间无响应，已跳过。",
        "이 디렉터리가 응답하지 않아 건너뛰었습니다.",
        "Каталог не отвечает, поэтому он был пропущен.",
        "Esta carpeta no respondió, así que se omitió.",
        "このディレクトリが応答しないためスキップしました。",
        "Ce dossier n’a pas répondu, il a donc été ignoré.",
        "Dieses Verzeichnis hat nicht geantwortet und wurde übersprungen.",
    ],

    # --- Cleanup -----------------------------------------------------------
    "cleanup.category.applicationCache": ["App caches", "应用缓存", "앱 캐시", "Кэши приложений", "Cachés de apps", "アプリのキャッシュ", "Caches d’apps", "App-Caches"],
    "cleanup.category.logs": ["Logs", "系统日志", "로그", "Логи", "Registros", "ログ", "Journaux", "Protokolle"],
    "cleanup.category.installers": ["Old installers", "旧安装包", "오래된 설치 파일", "Старые установщики", "Instaladores antiguos", "古いインストーラ", "Anciens installateurs", "Alte Installer"],
    "cleanup.category.temporaryFiles": ["Temporary files", "临时文件", "임시 파일", "Временные файлы", "Archivos temporales", "一時ファイル", "Fichiers temporaires", "Temporäre Dateien"],
    "cleanup.category.largeFiles": ["Large files", "大文件", "큰 파일", "Большие файлы", "Archivos grandes", "大きいファイル", "Fichiers volumineux", "Große Dateien"],
    "cleanup.category.oldFiles": ["Old files", "旧文件", "오래된 파일", "Старые файлы", "Archivos antiguos", "古いファイル", "Fichiers anciens", "Alte Dateien"],
    "cleanup.category.duplicateFiles": ["Duplicate files", "重复文件", "중복 파일", "Дубликаты файлов", "Archivos duplicados", "重複ファイル", "Doublons", "Duplikate"],
    "cleanup.category.applicationResidue": ["App leftovers", "应用残留", "앱 잔여 파일", "Остатки приложений", "Restos de apps", "アプリの残留物", "Résidus d’apps", "App-Reste"],
    "cleanup.category.developerArtifacts": ["Developer artifacts", "开发构建产物", "개발 빌드 산출물", "Артефакты сборки", "Artefactos de compilación", "ビルド生成物", "Artefacts de compilation", "Build-Artefakte"],


    "cleanup.explanation.cache": [
        "Apps rebuild these files the next time they run.",
        "应用下次运行时会重新生成这些文件。",
        "앱이 다음 실행 시 이 파일들을 다시 만듭니다.",
        "Приложения создадут эти файлы заново при следующем запуске.",
        "Las apps regeneran estos archivos la próxima vez que se ejecutan.",
        "アプリは次回起動時にこれらのファイルを再作成します。",
        "Les apps recréent ces fichiers à leur prochaine ouverture.",
        "Apps erzeugen diese Dateien beim nächsten Start neu.",
    ],
    "cleanup.explanation.logs": [
        "Log files older than %d days. They do not affect how apps run.",
        "%d 天前的日志文件。不影响应用正常运行。",
        "%d일이 지난 로그 파일입니다. 앱 실행에 영향을 주지 않습니다.",
        "Файлы журналов старше %d дней. Они не влияют на работу приложений.",
        "Archivos de registro de más de %d días. No afectan al funcionamiento de las apps.",
        "%d 日より前のログファイルです。アプリの動作には影響しません。",
        "Journaux de plus de %d jours. Sans effet sur le fonctionnement des apps.",
        "Protokolldateien älter als %d Tage. Sie beeinflussen Apps nicht.",
    ],
    # The `…Item` keys are what an individual cleanup item carries. The scanner
    # hands one key per item and the row renders it with no arguments, so these
    # sentences hold no `%d`/`%@`: the parameterised sentences above belong to the
    # category line, which the page formats with the number it knows.
    "cleanup.explanation.logsItem": [
        "Stale log files. Removing them does not change how apps run.",
        "过期日志文件。删除它们不会影响应用运行。",
        "오래된 로그 파일입니다. 삭제해도 앱 실행에는 영향이 없습니다.",
        "Устаревшие файлы журналов. Их удаление не влияет на работу приложений.",
        "Archivos de registro obsoletos. Eliminarlos no afecta al funcionamiento de las apps.",
        "古いログファイルです。削除してもアプリの動作には影響しません。",
        "Journaux obsolètes. Les supprimer ne change rien au fonctionnement des apps.",
        "Veraltete Protokolldateien. Ihr Entfernen ändert nichts an der Arbeitsweise der Apps.",
    ],
    "cleanup.explanation.systemLogsItem": [
        "Stale system log files. Reading some of them needs Full Disk Access.",
        "过期的系统日志文件。读取其中一部分需要“完全磁盘访问权限”。",
        "오래된 시스템 로그 파일입니다. 일부를 읽으려면 전체 디스크 접근 권한이 필요합니다.",
        "Устаревшие системные журналы. Для чтения некоторых нужен полный доступ к диску.",
        "Archivos de registro del sistema obsoletos. Leer algunos requiere acceso total al disco.",
        "古いシステムログファイルです。一部の読み取りにはフルディスクアクセスが必要です。",
        "Journaux système obsolètes. En lire certains nécessite un accès complet au disque.",
        "Veraltete Systemprotokolle. Zum Lesen einiger ist Vollzugriff auf die Festplatte nötig.",
    ],
    "cleanup.explanation.installers": [
        "Installers you already used. You may still need them, so confirm first.",
        "已经使用过的安装包。你可能仍需要它们，请先确认。",
        "이미 사용한 설치 파일입니다. 필요할 수 있으니 먼저 확인하세요.",
        "Установщики, которые вы уже использовали. Они могут ещё понадобиться.",
        "Instaladores que ya usaste. Puede que aún los necesites, confirma antes.",
        "使用済みのインストーラです。必要になる場合があるため確認してください。",
        "Installateurs déjà utilisés. Vous pourriez en avoir besoin, vérifiez.",
        "Bereits verwendete Installer. Sie könnten sie noch brauchen – bitte prüfen.",
    ],
    "cleanup.explanation.temporary": [
        "Scratch files left behind by apps.",
        "应用留下的临时文件。",
        "앱이 남긴 임시 파일입니다.",
        "Временные файлы, оставленные приложениями.",
        "Archivos temporales que dejan las apps.",
        "アプリが残した一時ファイルです。",
        "Fichiers temporaires laissés par les apps.",
        "Von Apps hinterlassene Temporärdateien.",
    ],
    "cleanup.explanation.buildArtifacts": ["Output a compiler wrote. The next build creates it again.", "编译器写出的构建产物，重新编译就会再次生成。", "컴파일러가 만든 빌드 산출물입니다. 다시 빌드하면 생성됩니다.", "Результат работы компилятора. Следующая сборка создаст его снова.", "Resultado de una compilación. La próxima compilación lo vuelve a crear.", "コンパイラが出力したビルド生成物です。次回のビルドで再生成されます。", "Résultat d’une compilation. La prochaine compilation le recréera.", "Ausgabe eines Compilers. Der nächste Build erzeugt sie erneut."],
    "cleanup.explanation.xcodeArchives": [
        "Archived builds. A project can be archived again, but this archive cannot be recovered.",
        "归档的构建产物。项目可以重新归档，但这份归档无法恢复。",
        "보관된 빌드 결과물입니다. 프로젝트를 다시 아카이브할 수는 있지만 이 아카이브는 복구할 수 없습니다.",
        "Архивные сборки. Проект можно заархивировать заново, но этот архив восстановить нельзя.",
        "Compilaciones archivadas. El proyecto se puede archivar de nuevo, pero este archivo no se puede recuperar.",
        "アーカイブされたビルドです。プロジェクトは再アーカイブできますが、このアーカイブは復元できません。",
        "Compilations archivées. Le projet peut être réarchivé, mais cette archive ne peut pas être récupérée.",
        "Archivierte Builds. Das Projekt lässt sich erneut archivieren, dieses Archiv jedoch nicht wiederherstellen.",
    ],
    "cleanup.explanation.simulatorDevices": [
        "Simulator devices and everything installed in them. The device can be created again; the apps inside it must be installed again.",
        "模拟器设备及其内部安装的内容。设备可以重新创建，里面的应用需要重新安装。",
        "시뮬레이터 기기와 그 안에 설치된 모든 항목입니다. 기기는 다시 만들 수 있지만 안의 앱은 다시 설치해야 합니다.",
        "Устройства симулятора и всё, что в них установлено. Устройство можно создать заново, а приложения в нём придётся устанавливать снова.",
        "Dispositivos del simulador y todo lo instalado en ellos. El dispositivo se puede crear de nuevo; las apps que contiene hay que instalarlas otra vez.",
        "シミュレータのデバイスとその中にインストールされたものすべて。デバイスは作り直せますが、中のアプリは入れ直す必要があります。",
        "Appareils du simulateur et tout ce qui y est installé. L’appareil peut être recréé ; les apps qu’il contient doivent être réinstallées.",
        "Simulator-Geräte und alles, was darin installiert ist. Das Gerät lässt sich neu anlegen; die Apps darin müssen neu installiert werden.",
    ],
    "cleanup.explanation.largeFiles": [
        "Files larger than %@. Sift never guesses: you decide which to remove.",
        "大于 %@ 的文件。Sift 不做猜测，由你决定删除哪些。",
        "%@보다 큰 파일입니다. 어떤 파일을 지울지는 사용자가 결정합니다.",
        "Файлы больше %@. Sift не угадывает: решение за вами.",
        "Archivos de más de %@. Sift no adivina: tú decides cuáles eliminar.",
        "%@ を超えるファイルです。削除するかどうかはご自身で決められます。",
        "Fichiers de plus de %@. Sift ne devine pas : c’est vous qui décidez.",
        "Dateien größer als %@. Sift rät nicht – Sie entscheiden.",
    ],
    "cleanup.explanation.largeFilesItem": [
        "A large file. Sift never guesses: you decide which to remove.",
        "大文件。Sift 不做猜测，由你决定删除哪些。",
        "큰 파일입니다. 지울지는 사용자가 결정합니다.",
        "Большой файл. Sift не угадывает: решение за вами.",
        "Un archivo grande. Sift no adivina: tú decides cuáles eliminar.",
        "大きなファイルです。削除するかどうかはご自身で決められます。",
        "Un fichier volumineux. Sift ne devine pas : c’est vous qui décidez.",
        "Eine große Datei. Sift rät nicht – Sie entscheiden.",
    ],
    "cleanup.explanation.oldFiles": [
        "Not modified for %d days and larger than 10 MB.",
        "%d 天未修改且大于 10 MB。",
        "%d일 동안 수정되지 않았고 10MB 이상입니다.",
        "Не изменялись %d дней и больше 10 МБ.",
        "Sin cambios durante %d días y mayores de 10 MB.",
        "%d 日以上変更がなく、10 MB を超えるファイルです。",
        "Non modifiés depuis %d jours et de plus de 10 Mo.",
        "Seit %d Tagen unverändert und größer als 10 MB.",
    ],
    "cleanup.explanation.oldFilesItem": [
        "Not modified for a long time, and larger than 10 MB.",
        "长期未修改且大于 10 MB。",
        "오랫동안 수정되지 않았고 10MB 이상입니다.",
        "Давно не изменялись и больше 10 МБ.",
        "Sin cambios durante mucho tiempo y mayores de 10 MB.",
        "長期間変更がなく、10 MB を超えるファイルです。",
        "Non modifiés depuis longtemps et de plus de 10 Mo.",
        "Seit langem unverändert und größer als 10 MB.",
    ],
    "cleanup.explanation.duplicates": [
        "Identical content. Keep one copy and remove the rest.",
        "内容完全相同。保留一份，删除其余。",
        "내용이 완전히 동일합니다. 하나만 남기고 나머지를 삭제하세요.",
        "Идентичное содержимое. Оставьте одну копию и удалите остальные.",
        "Contenido idéntico. Conserva una copia y elimina el resto.",
        "内容が完全に同じです。1 つを残して他を削除します。",
        "Contenu identique. Gardez une copie et supprimez les autres.",
        "Identischer Inhalt. Eine Kopie behalten, den Rest entfernen.",
    ],
    "cleanup.explanation.residue": [
        "Left over from an app that is no longer installed.",
        "来自已卸载应用的残留文件。",
        "더 이상 설치되지 않은 앱의 잔여 파일입니다.",
        "Осталось от приложения, которое больше не установлено.",
        "Restos de una app que ya no está instalada.",
        "アンインストール済みアプリの残留ファイルです。",
        "Reste d’une app qui n’est plus installée.",
        "Rest einer nicht mehr installierten App.",
    ],
    "cleanup.explanation.residuePreferences": [
        "Preference file without a matching installed app.",
        "没有对应已安装应用的偏好设置文件。",
        "설치된 앱과 일치하지 않는 환경설정 파일입니다.",
        "Файл настроек без соответствующего установленного приложения.",
        "Archivo de preferencias sin una app instalada correspondiente.",
        "対応するアプリがない環境設定ファイルです。",
        "Fichier de préférences sans app installée correspondante.",
        "Einstellungsdatei ohne passende installierte App.",
    ],
    "cleanup.explanation.residueWebStorage": [
        "Web storage for an app that is no longer installed.",
        "已卸载应用的网页存储数据。",
        "더 이상 설치되지 않은 앱의 웹 저장 데이터입니다.",
        "Веб-хранилище приложения, которое больше не установлено.",
        "Almacenamiento web de una app que ya no está instalada.",
        "アンインストール済みアプリの Web ストレージです。",
        "Stockage web d’une app qui n’est plus installée.",
        "Web-Speicher einer nicht mehr installierten App.",
    ],
    "cleanup.explanation.residueGroupContainer": [
        "Shared container of an app that is no longer installed.",
        "已卸载应用的共享容器。",
        "더 이상 설치되지 않은 앱의 공유 컨테이너입니다.",
        "Общий контейнер приложения, которое больше не установлено.",
        "Contenedor compartido de una app que ya no está instalada.",
        "アンインストール済みアプリの共有コンテナです。",
        "Conteneur partagé d’une app qui n’est plus installée.",
        "Gemeinsamer Container einer nicht mehr installierten App.",
    ],
    "cleanup.explanation.savedState": [
        "Window state saved for apps that are no longer running.",
        "为已退出的应用保存的窗口状态。",
        "종료된 앱의 창 상태 저장 파일입니다.",
        "Сохранённое состояние окон для закрытых приложений.",
        "Estado de ventanas guardado de apps que ya no están abiertas.",
        "終了したアプリのウィンドウ状態の保存ファイルです。",
        "État de fenêtres enregistré pour des apps fermées.",
        "Gespeicherter Fensterzustand nicht laufender Apps.",
    ],

    "risk.safe.short": ["Safe", "安全", "안전", "Безопасно", "Seguro", "安全", "Sûr", "Sicher"],
    "risk.review.short": ["Review", "需确认", "확인 필요", "Проверить", "Revisar", "要確認", "À vérifier", "Prüfen"],
    "risk.protected.short": ["Protected", "受保护", "보호됨", "Защищено", "Protegido", "保護", "Protégé", "Geschützt"],
    "risk.safe.detail": [
        "Rebuilt automatically if needed. Selected by default.",
        "需要时会自动重建。默认已选中。",
        "필요하면 자동으로 다시 생성됩니다. 기본 선택됨.",
        "При необходимости создаётся заново. Выбрано по умолчанию.",
        "Se regenera automáticamente si hace falta. Seleccionado por defecto.",
        "必要になれば自動で再作成されます。既定で選択されます。",
        "Recréé automatiquement si nécessaire. Sélectionné par défaut.",
        "Wird bei Bedarf neu erzeugt. Standardmäßig ausgewählt.",
    ],
    "risk.review.detail": [
        "Usually safe to remove, but you should confirm.",
        "通常可以删除，但建议你确认。",
        "보통 삭제해도 안전하지만 확인이 필요합니다.",
        "Обычно можно удалить, но лучше подтвердить.",
        "Normalmente se puede eliminar, pero conviene confirmar.",
        "通常は削除できますが、確認をおすすめします。",
        "Généralement supprimable, mais à confirmer.",
        "Meist unbedenklich, aber bitte bestätigen.",
    ],
    "risk.protected.detail": [
        "Sift will not remove this. It is shown for information only.",
        "Sift 不会删除此处内容，仅作说明。",
        "Sift는 이 항목을 삭제하지 않습니다. 정보 제공용입니다.",
        "Sift это не удаляет. Показано только для информации.",
        "Sift no elimina esto. Solo se muestra a modo informativo.",
        "Sift は削除しません。情報としてのみ表示します。",
        "Sift ne le supprimera pas. Affiché à titre informatif.",
        "Sift entfernt das nicht. Nur zur Information.",
    ],

    "cleanup.confirm.title": ["Move to Trash?", "移入废纸篓？", "휴지통으로 이동할까요?", "Переместить в Корзину?", "¿Mover a la papelera?", "ゴミ箱に入れますか？", "Déplacer vers la corbeille ?", "In den Papierkorb?"],
    "cleanup.confirm.moveCount": [
        "Move %d items to Trash, %@ in total",
        "将 %d 个项目移入废纸篓，共 %@",
        "%d개 항목을 휴지통으로 이동, 총 %@",
        "Переместить элементов: %d, всего %@",
        "Mover %d elementos a la papelera, %@ en total",
        "%d 個の項目をゴミ箱へ移動、合計 %@",
        "Déplacer %d éléments vers la corbeille, %@ au total",
        "%d Einträge in den Papierkorb, insgesamt %@",
    ],
    "cleanup.confirm.moveCountOne": [
        "Move 1 item to Trash, %@ in total",
        "将 1 个项目移入废纸篓，共 %@",
        "1개 항목을 휴지통으로 이동, 총 %@",
        "Переместить 1 элемент, всего %@",
        "Mover 1 elemento a la papelera, %@ en total",
        "1 個の項目をゴミ箱へ移動、合計 %@",
        "Déplacer 1 élément vers la corbeille, %@",
        "1 Eintrag in den Papierkorb, insgesamt %@",
    ],
    "cleanup.confirm.undoNotice": [
        "Everything goes to the Trash, so you can put it back until you empty it.",
        "所有内容都会进入废纸篓，在清空前都可以恢复。",
        "모든 항목은 휴지통으로 이동하며, 비우기 전까지 되돌릴 수 있습니다.",
        "Всё перемещается в Корзину, поэтому можно вернуть до её очистки.",
        "Todo va a la papelera, así que puedes recuperarlo hasta que la vacíes.",
        "すべてゴミ箱に入るため、空にするまで元に戻せます。",
        "Tout va à la corbeille : vous pouvez restaurer jusqu’à ce que vous la vidiez.",
        "Alles landet im Papierkorb und kann bis zum Leeren zurückgeholt werden.",
    ],
    "cleanup.confirm.selectedItems": ["%d selected", "已选 %d 项", "%d개 선택됨", "Выбрано: %d", "%d seleccionados", "%d 件を選択", "%d sélectionnés", "%d ausgewählt"],
    "cleanup.confirm.methodValue": ["Move to Trash (recoverable)", "移入废纸篓（可恢复）", "휴지통으로 이동 (복구 가능)", "Переместить в Корзину (можно вернуть)", "Mover a la papelera (recuperable)", "ゴミ箱へ移動（復元可能）", "Déplacer vers la corbeille (récupérable)", "In den Papierkorb (wiederherstellbar)"],
    "cleanup.confirm.cancel": ["Cancel", "取消", "취소", "Отмена", "Cancelar", "キャンセル", "Annuler", "Abbrechen"],
    "cleanup.confirm.skipConfirmation": ["Skip confirmation next time", "下次跳过确认", "다음부터 확인 건너뛰기", "Не спрашивать в следующий раз", "Omitir la confirmación la próxima vez", "次回から確認しない", "Ne plus demander la prochaine fois", "Nächstes Mal nicht mehr fragen"],
    "cleanup.confirm.riskWarning": [
        "You have included items marked for review. Please check the list before continuing.",
        "你已选中标记为需确认的项目。继续前请检查列表。",
        "확인이 필요한 항목이 포함되어 있습니다. 계속하기 전에 목록을 확인하세요.",
        "Вы выбрали элементы с пометкой «проверить». Проверьте список перед продолжением.",
        "Has incluido elementos marcados para revisar. Comprueba la lista antes de continuar.",
        "要確認の項目が含まれています。続行前にリストを確認してください。",
        "Vous avez inclus des éléments à vérifier. Vérifiez la liste avant de continuer.",
        "Sie haben Einträge mit „prüfen“ ausgewählt. Bitte prüfen Sie die Liste.",
    ],

    "cleanup.result.title": ["Cleanup finished", "清理完成", "정리 완료", "Очистка завершена", "Limpieza finalizada", "クリーンアップ完了", "Nettoyage terminé", "Bereinigung abgeschlossen"],
    "cleanup.result.moved": ["%d items moved to Trash", "%d 个项目已移入废纸篓", "%d개 항목을 휴지통으로 이동", "Элементов перемещено: %d", "%d elementos movidos a la papelera", "%d 個をゴミ箱へ移動しました", "%d éléments déplacés vers la corbeille", "%d Einträge in den Papierkorb verschoben"],
    "cleanup.result.released": ["Released %@", "释放 %@", "%@ 확보", "Освобождено %@", "Liberados %@", "%@ を解放しました", "%@ libérés", "%@ freigegeben"],
    "cleanup.result.showTrash": ["Show Trash in Finder", "在访达中查看废纸篓", "Finder에서 휴지통 열기", "Показать Корзину в Finder", "Mostrar la papelera en el Finder", "Finder でゴミ箱を表示", "Afficher la corbeille dans le Finder", "Papierkorb im Finder zeigen"],
    "cleanup.result.undoHint": [
        "Put items back from the Trash until you empty it.",
        "在清空废纸篓之前，你可以随时恢复这些项目。",
        "휴지통을 비우기 전까지 항목을 되돌릴 수 있습니다.",
        "Верните элементы из Корзины, пока не очистили её.",
        "Recupera los elementos de la papelera mientras no la vacíes.",
        "ゴミ箱を空にするまで、項目を元に戻せます。",
        "Restaurez les éléments depuis la corbeille tant qu’elle n’est pas vidée.",
        "Holen Sie Einträge aus dem Papierkorb zurück, solange er nicht geleert ist.",
    ],
    "cleanup.result.details": ["Item details", "项目明细", "항목 세부 정보", "Подробности", "Detalles de los elementos", "項目の詳細", "Détail des éléments", "Eintragsdetails"],
    "cleanup.result.exportReport": ["Export report as PDF", "导出报告为 PDF", "보고서를 PDF로 내보내기", "Экспорт отчёта в PDF", "Exportar informe a PDF", "レポートを PDF で書き出す", "Exporter le rapport en PDF", "Bericht als PDF exportieren"],

    "cleanup.failure.permissionDenied": ["Needs disk access", "需要磁盘访问权限", "디스크 접근 권한 필요", "Нужен доступ к диску", "Necesita acceso al disco", "ディスクへのアクセスが必要", "Accès au disque requis", "Datenträgerzugriff nötig"],
    "cleanup.failure.fileNotFound": ["Already removed", "已被移除", "이미 제거됨", "Уже удалено", "Ya eliminado", "すでに削除済み", "Déjà supprimé", "Bereits entfernt"],
    "cleanup.failure.fileInUse": ["In use, skipped", "应用占用中，未处理", "사용 중이라 건너뜀", "Используется, пропущено", "En uso, omitido", "使用中のためスキップ", "Utilisé, ignoré", "In Verwendung, übersprungen"],
    # The path no longer resolves to what the user selected: the item was moved,
    # or an ancestor was replaced by a symlink, between the pre-flight check and
    # the move. Refused rather than followed.
    "cleanup.failure.itemChanged": ["Changed, skipped", "文件已变动，未处理", "변경되어 건너뜀", "Изменено, пропущено", "Cambiado, omitido", "変更のためスキップ", "Modifié, ignoré", "Geändert, übersprungen"],
    "cleanup.failure.volumeUnavailable": ["Disk disconnected", "磁盘已断开", "디스크 연결 끊김", "Диск отключён", "Disco desconectado", "ディスクが接続されていません", "Disque déconnecté", "Datenträger getrennt"],
    "cleanup.failure.protectedLocation": ["Protected location", "受保护的位置", "보호된 위치", "Защищённое место", "Ubicación protegida", "保護された場所", "Emplacement protégé", "Geschützter Ort"],
    "cleanup.failure.partialFailure": ["Partly done", "部分完成", "일부만 완료", "Выполнено частично", "Hecho en parte", "一部のみ完了", "Partiellement fait", "Teilweise erledigt"],

    # --- Uninstaller -------------------------------------------------------
    "uninstall.search": ["Search apps", "搜索应用", "앱 검색", "Поиск приложений", "Buscar apps", "アプリを検索", "Rechercher des apps", "Apps suchen"],
    "uninstall.sort.name": ["Name", "名称", "이름", "Имя", "Nombre", "名前", "Nom", "Name"],
    "uninstall.sort.size": ["Size", "占用空间", "크기", "Размер", "Tamaño", "サイズ", "Taille", "Größe"],
    "uninstall.sort.lastUsed": ["Last used", "最近使用", "최근 사용", "Последнее использование", "Último uso", "最終使用", "Dernière utilisation", "Zuletzt verwendet"],
    "uninstall.noneInstalled": ["No third-party apps found", "没有找到第三方应用", "서드파티 앱이 없습니다", "Сторонние приложения не найдены", "No se encontraron apps de terceros", "サードパーティ製アプリが見つかりません", "Aucune app tierce trouvée", "Keine Apps von Drittanbietern gefunden"],
    "uninstall.systemApp": ["Cannot be uninstalled", "不可卸载", "제거할 수 없음", "Нельзя удалить", "No se puede desinstalar", "アンインストールできません", "Ne peut pas être désinstallé", "Kann nicht deinstalliert werden"],
    "uninstall.systemAppDetail": [
        "Sift only removes apps you installed yourself.",
        "Sift 只处理你自己安装的应用。",
        "Sift는 직접 설치한 앱만 제거합니다.",
        "Sift удаляет только приложения, установленные вами.",
        "Sift solo elimina apps que instalaste tú.",
        "Sift はご自身でインストールしたアプリのみ削除します。",
        "Sift ne supprime que les apps que vous avez installées.",
        "Sift entfernt nur Apps, die Sie selbst installiert haben.",
    ],
    "uninstall.needsReview": ["Needs your confirmation", "需要手动确认", "확인 필요", "Требуют подтверждения", "Necesitan tu confirmación", "確認が必要", "À confirmer", "Prüfung erforderlich"],
    # Why a file was matched to an application. Shown with the files that need
    # confirming, which is where the user has to weigh the match (§5.3).
    "uninstall.reason.bundleIdentifier": [
        "The name is this app's bundle identifier.",
        "名称就是该应用的 bundle identifier。",
        "이름이 이 앱의 번들 ID입니다.",
        "Имя совпадает с идентификатором этого приложения.",
        "El nombre es el identificador de esta app.",
        "名前がこのアプリの Bundle ID です。",
        "Le nom est l’identifiant de cette app.",
        "Der Name ist die Bundle-ID dieser App.",
    ],
    "uninstall.reason.identifierPrefix": [
        "The name starts with this app's bundle identifier.",
        "名称以该应用的 bundle identifier 开头。",
        "이름이 이 앱의 번들 ID로 시작합니다.",
        "Имя начинается с идентификатора этого приложения.",
        "El nombre empieza por el identificador de esta app.",
        "名前がこのアプリの Bundle ID で始まります。",
        "Le nom commence par l’identifiant de cette app.",
        "Der Name beginnt mit der Bundle-ID dieser App.",
    ],
    "uninstall.reason.applicationName": [
        "The name is exactly the application name, in a folder macOS keeps per app.",
        "名称与应用名完全一致，且位于 macOS 按应用存放数据的目录。",
        "이름이 앱 이름과 정확히 일치하며, macOS가 앱별로 사용하는 폴더입니다.",
        "Имя точно совпадает с приложением, и папка предназначена для данных приложений.",
        "El nombre coincide exactamente y la carpeta es la que macOS usa por app.",
        "名前がアプリ名と完全に一致し、macOS がアプリごとに使うフォルダーです。",
        "Le nom correspond exactement, dans un dossier que macOS réserve aux apps.",
        "Der Name stimmt genau überein, in einem Ordner, den macOS je App verwendet.",
    ],
    "uninstall.reason.identifierSuffix": [
        "The name matches the last part of this app's bundle identifier.",
        "名称与该应用 bundle identifier 的最后一段一致。",
        "이름이 이 앱 번들 ID의 마지막 부분과 일치합니다.",
        "Имя совпадает с последней частью идентификатора этого приложения.",
        "El nombre coincide con la última parte del identificador de esta app.",
        "名前がこのアプリの Bundle ID の最後の部分と一致します。",
        "Le nom correspond à la dernière partie de l’identifiant de cette app.",
        "Der Name entspricht dem letzten Teil der Bundle-ID dieser App.",
    ],
    "uninstall.reason.appGroup": ["The container belongs to an app group this app declares.", "该容器属于此应用声明的应用组。", "이 앱이 선언한 앱 그룹에 속한 컨테이너입니다.", "Контейнер принадлежит группе приложений, объявленной этим приложением.", "El contenedor pertenece a un grupo de apps declarado por esta app.", "このアプリが宣言するアプリグループのコンテナです。", "Le conteneur appartient à un groupe d’apps déclaré par cette app.", "Der Container gehört zu einer App-Gruppe, die diese App deklariert."],
    "uninstall.copyGroupIdentifier": ["Copy group identifier", "拷贝组标识符", "앱 그룹 식별자 복사", "Скопировать идентификатор группы", "Copiar identificador del grupo", "グループ識別子をコピー", "Copier l’identifiant de groupe", "Gruppen-ID kopieren"],
    "uninstall.appRunning": [
        "%@ is running. Quit it before removing, or Sift will skip the files it holds open.",
        "%@ 正在运行。请先退出，否则 Sift 会跳过被占用的文件。",
        "%@이(가) 실행 중입니다. 먼저 종료하지 않으면 사용 중인 파일은 건너뜁니다.",
        "%@ запущено. Закройте его, иначе Sift пропустит занятые файлы.",
        "%@ se está ejecutando. Ciérrala antes, o Sift omitirá los archivos en uso.",
        "%@ が実行中です。先に終了しないと、使用中のファイルはスキップされます。",
        "%@ est en cours d’exécution. Quittez-le, sinon Sift ignorera les fichiers ouverts.",
        "%@ läuft. Beenden Sie es, sonst überspringt Sift die geöffneten Dateien.",
    ],
    "uninstall.quitFailed": [
        "Sift could not ask %@ to quit. Quit it manually and try again.",
        "Sift 无法请求 %@ 退出。请手动退出后重试。",
        "Sift가 %@에 종료를 요청하지 못했습니다. 직접 종료한 뒤 다시 시도하세요.",
        "Sift не удалось попросить %@ завершить работу. Закройте его вручную и повторите.",
        "Sift no pudo pedir a %@ que se cerrara. Ciérrala manualmente e inténtalo de nuevo.",
        "Sift は %@ に終了を要求できませんでした。手動で終了してから再試行してください。",
        "Sift n’a pas pu demander à %@ de quitter. Quittez-le manuellement et réessayez.",
        "Sift konnte %@ nicht zum Beenden auffordern. Beenden Sie es manuell und versuchen Sie es erneut.",
    ],
    "uninstall.noRelatedFiles": ["No related files were found.", "没有找到关联文件。", "관련 파일을 찾지 못했습니다.", "Связанные файлы не найдены.", "No se encontraron archivos relacionados.", "関連ファイルは見つかりませんでした。", "Aucun fichier associé trouvé.", "Keine zugehörigen Dateien gefunden."],
    "uninstall.selectApp": ["Choose an app to see what would be removed.", "选择一个应用以查看将被删除的内容。", "앱을 선택하면 제거될 항목을 볼 수 있습니다.", "Выберите приложение, чтобы увидеть, что будет удалено.", "Elige una app para ver qué se eliminaría.", "アプリを選択すると削除内容を確認できます。", "Choisissez une app pour voir ce qui serait supprimé.", "Wählen Sie eine App, um zu sehen, was entfernt würde."],

    # --- File cleanup ------------------------------------------------------
    "files.mode.large": ["Large files", "大文件", "큰 파일", "Большие файлы", "Archivos grandes", "大きいファイル", "Fichiers volumineux", "Große Dateien"],
    "files.mode.old": ["Old files", "旧文件", "오래된 파일", "Старые файлы", "Archivos antiguos", "古いファイル", "Fichiers anciens", "Alte Dateien"],
    "files.mode.duplicates": ["Duplicates", "重复文件", "중복 파일", "Дубликаты", "Duplicados", "重複ファイル", "Doublons", "Duplikate"],
    "files.duplicateGroups": ["%d duplicate groups, %@ reclaimable", "%d 个重复组，可释放 %@", "중복 그룹 %d개, %@ 확보 가능", "Групп дубликатов: %d, можно освободить %@", "%d grupos de duplicados, %@ recuperables", "重複グループ %d 件、%@ を解放可能", "%d groupes de doublons, %@ récupérables", "%d Duplikatgruppen, %@ freigebbar"],
    # Shown when the group list is paged: the user has to be able to tell how
    # much of the result they are looking at.
    "files.duplicateGroupsShown": ["Showing %d of %d groups", "已显示 %d / %d 组", "%d / %d 그룹 표시", "Показано %d из %d групп", "Mostrando %d de %d grupos", "%d / %d グループを表示", "%d groupes sur %d affichés", "%d von %d Gruppen angezeigt"],
    "files.groupMembers": ["%d copies", "%d 份副本", "%d개 사본", "Копий: %d", "%d copias", "%d 個のコピー", "%d copies", "%d Kopien"],
    "files.keepThis": ["Keep this one", "保留此项", "이 항목 유지", "Оставить этот", "Conservar este", "これを残す", "Conserver celui-ci", "Diese behalten"],
    "files.noDuplicates": ["No duplicate files found", "没有找到重复文件", "중복 파일이 없습니다", "Дубликаты не найдены", "No se encontraron duplicados", "重複ファイルは見つかりませんでした", "Aucun doublon trouvé", "Keine Duplikate gefunden"],
    "files.revealInFinder": ["Show in Finder", "在访达中显示", "Finder에서 보기", "Показать в Finder", "Mostrar en el Finder", "Finder で表示", "Afficher dans le Finder", "Im Finder zeigen"],
    "files.requiresAuthorization": [
        "Sift scans Downloads, Desktop and folders you choose. Add a folder to include it.",
        "Sift 只扫描下载、桌面和你选择的文件夹。添加文件夹以纳入扫描。",
        "Sift는 다운로드, 데스크톱 및 선택한 폴더만 검사합니다. 폴더를 추가하세요.",
        "Sift сканирует «Загрузки», «Рабочий стол» и выбранные папки. Добавьте папку.",
        "Sift analiza Descargas, Escritorio y las carpetas que elijas. Añade una carpeta.",
        "Sift はダウンロード、デスクトップ、選択したフォルダを対象にします。フォルダを追加してください。",
        "Sift analyse Téléchargements, le Bureau et les dossiers choisis. Ajoutez un dossier.",
        "Sift prüft Downloads, Schreibtisch und von Ihnen gewählte Ordner. Ordner hinzufügen.",
    ],
    "files.addFolder": ["Add folder", "添加文件夹", "폴더 추가", "Добавить папку", "Añadir carpeta", "フォルダを追加", "Ajouter un dossier", "Ordner hinzufügen"],

    # --- System diagnostics ------------------------------------------------
    "diagnostics.category.spotlightIndex": ["Spotlight index", "Spotlight 索引", "Spotlight 색인", "Индекс Spotlight", "Índice de Spotlight", "Spotlight インデックス", "Index Spotlight", "Spotlight-Index"],
    "diagnostics.category.coreSpotlightIndex": ["Search metadata", "搜索元数据", "검색 메타데이터", "Метаданные поиска", "Metadatos de búsqueda", "検索メタデータ", "Métadonnées de recherche", "Suchmetadaten"],
    "diagnostics.category.developerIndex": ["Development index", "开发工具索引", "개발 도구 색인", "Индекс средств разработки", "Índice de desarrollo", "開発ツールの索引", "Index de développement", "Entwicklungsindex"],
    "diagnostics.category.applicationDatabase": ["Application database", "应用数据库", "앱 데이터베이스", "База данных приложения", "Base de datos de la app", "アプリのデータベース", "Base de données d’app", "App-Datenbank"],
    "diagnostics.category.filesystemSnapshot": ["APFS snapshot", "APFS 快照", "APFS 스냅샷", "Снимок APFS", "Instantánea APFS", "APFS スナップショット", "Instantané APFS", "APFS-Snapshot"],
    "diagnostics.category.systemCache": ["System cache", "系统缓存", "시스템 캐시", "Системный кэш", "Caché del sistema", "システムキャッシュ", "Cache système", "Systemcache"],
    "diagnostics.category.systemData": ["System data", "系统数据", "시스템 데이터", "Системные данные", "Datos del sistema", "システムデータ", "Données système", "Systemdaten"],
    "diagnostics.category.userData": ["Your data", "你的资料", "사용자 데이터", "Ваши данные", "Tus datos", "ユーザデータ", "Vos données", "Ihre Daten"],
    "diagnostics.category.unknown": ["Unclassified", "未分类", "미분류", "Без категории", "Sin clasificar", "未分類", "Non classé", "Nicht eingestuft"],
    "diagnostics.status.cleanable": ["Can be cleaned", "可清理", "정리 가능", "Можно очистить", "Se puede limpiar", "整理できます", "Peut être nettoyé", "Kann bereinigt werden"],
    "diagnostics.status.rebuildable": ["Can be rebuilt", "可以重建", "다시 만들 수 있음", "Можно перестроить", "Se puede reconstruir", "再構築できます", "Peut être reconstruit", "Kann neu aufgebaut werden"],
    "diagnostics.status.protected": ["Protected", "受保护", "보호됨", "Защищено", "Protegido", "保護されています", "Protégé", "Geschützt"],
    "diagnostics.status.unknown": ["Not judged", "无法判断", "판단 보류", "Не оценено", "Sin evaluar", "判断しません", "Non évalué", "Nicht bewertet"],
    "diagnostics.remediation.trash": ["Moves to the Trash after you confirm", "确认后移入废纸篓", "확인 후 휴지통으로 이동", "Перемещается в Корзину после подтверждения", "Se mueve a la Papelera tras confirmar", "確認後にゴミ箱へ移動します", "Déplacé vers la Corbeille après confirmation", "Wird nach Bestätigung in den Papierkorb gelegt"],
    "diagnostics.remediation.spotlight": ["Rebuild it with Spotlight: mdutil -E", "用 Spotlight 重建：mdutil -E", "Spotlight로 다시 만들기: mdutil -E", "Перестроить в Spotlight: mdutil -E", "Reconstruir con Spotlight: mdutil -E", "Spotlight で再構築: mdutil -E", "Reconstruire avec Spotlight : mdutil -E", "Mit Spotlight neu aufbauen: mdutil -E"],
    "diagnostics.remediation.owningApplication": ["Rebuild it from the tool that made it", "由生成它的工具重建", "만든 도구에서 다시 만들기", "Перестроить в создавшей программе", "Reconstruir desde la herramienta que lo creó", "作成したツールで再構築します", "Reconstruire depuis l’outil concerné", "Im erzeugenden Werkzeug neu aufbauen"],
    "diagnostics.remediation.inspectOnly": ["Shown for information only", "仅供参考，Sift 不会处理", "정보 제공만 하며 Sift는 처리하지 않습니다", "Только для сведения: Sift не изменяет", "Solo informativo: Sift no lo modifica", "情報表示のみで、Sift は操作しません", "Affichage informatif : Sift n’y touche pas", "Nur zur Information: Sift ändert nichts"],
    "diagnostics.coverage.complete": ["This result covers everything that was asked for.", "本次结果覆盖了全部请求的范围。", "요청한 범위를 모두 확인했습니다.", "Результат охватывает всю запрошенную область.", "Este resultado cubre todo lo solicitado.", "要求した範囲をすべて確認しました。", "Ce résultat couvre toute la portée demandée.", "Dieses Ergebnis deckt den gesamten angeforderten Bereich ab."],
    "diagnostics.coverage.partial": ["Part of the scope could not be measured, so the totals are a lower bound.", "部分范围无法统计，因此合计只是下限。", "일부 범위를 측정할 수 없어 합계는 최소값입니다.", "Часть области измерить не удалось, поэтому итоги — нижняя граница.", "Parte del alcance no se pudo medir, así que los totales son un mínimo.", "一部を測定できなかったため、合計は下限値です。", "Une partie de la portée n’a pas pu être mesurée : les totaux sont un minimum.", "Ein Teil des Bereichs war nicht messbar, die Summen sind also Untergrenzen."],
    "diagnostics.coverage.permissionDenied": ["Some locations need Full Disk Access before they can be measured.", "部分位置需要完全磁盘访问权限才能统计。", "일부 위치는 전체 디스크 접근 권한이 있어야 측정할 수 있습니다.", "Часть мест требует полного доступа к диску.", "Algunas ubicaciones necesitan acceso total al disco.", "一部の場所はフルディスクアクセスが必要です。", "Certains emplacements nécessitent un accès complet au disque.", "Einige Orte benötigen Vollzugriff auf die Festplatte."],
    "diagnostics.coverage.volumeUnavailable": ["A volume is no longer available, so it was not measured.", "有一个卷已不可用，未做统计。", "사용할 수 없는 볼륨이 있어 측정하지 않았습니다.", "Один том недоступен и не измерялся.", "Un volumen ya no está disponible y no se midió.", "利用できないボリュームがあり、測定していません。", "Un volume n’est plus disponible et n’a pas été mesuré.", "Ein Volume ist nicht mehr verfügbar und wurde nicht gemessen."],
    "diagnostics.explanation.volumeChild": ["A directory at the top level of the volume.", "卷根目录下的一个目录。", "볼륨 최상위의 디렉터리입니다.", "Каталог верхнего уровня тома.", "Un directorio en el nivel superior del volumen.", "ボリューム直下のフォルダです。", "Un dossier à la racine du volume.", "Ein Verzeichnis auf oberster Ebene des Volumes."],
    "diagnostics.explanation.systemData": ["Part of macOS or its libraries. It occupies space and cannot be removed.", "属于 macOS 或其系统库。它占用空间，但不能删除。", "macOS 또는 시스템 라이브러리의 일부입니다. 공간을 차지하지만 삭제할 수 없습니다.", "Часть macOS или её библиотек. Занимает место и не может быть удалена.", "Parte de macOS o de sus bibliotecas. Ocupa espacio y no se puede eliminar.", "macOS またはそのライブラリの一部です。容量を使いますが削除できません。", "Fait partie de macOS ou de ses bibliothèques. Occupe de l’espace et ne peut pas être supprimé.", "Teil von macOS oder dessen Bibliotheken. Belegt Platz und darf nicht entfernt werden."],
    "diagnostics.explanation.spotlightIndexed": ["Spotlight's index for this volume; indexing is currently on. macOS rebuilds it with mdutil -E — moving it to the Trash only makes search unavailable until it is rebuilt.", "此卷的 Spotlight 索引，索引服务当前已启用。macOS 可用 mdutil -E 重建；直接移入废纸篓只会让搜索在重建完成前不可用。", "이 볼륨의 Spotlight 색인이며 색인이 켜져 있습니다. macOS는 mdutil -E로 다시 만듭니다. 휴지통으로 옮기면 다시 만들어질 때까지 검색만 사용할 수 없게 됩니다.", "Индекс Spotlight для этого тома; индексация включена. macOS перестраивает его через mdutil -E — перемещение в Корзину лишь отключит поиск до перестроения.", "Índice de Spotlight de este volumen; la indexación está activada. macOS lo reconstruye con mdutil -E: moverlo a la Papelera solo deja la búsqueda inutilizable hasta que se reconstruya.", "このボリュームの Spotlight インデックスで、現在は索引が有効です。macOS は mdutil -E で再構築します。ゴミ箱に移しても、再構築が終わるまで検索が使えなくなるだけです。", "Index Spotlight de ce volume ; l’indexation est active. macOS le reconstruit avec mdutil -E : le placer dans la Corbeille rend simplement la recherche indisponible jusqu’à la reconstruction.", "Spotlight-Index dieses Volumes; die Indizierung ist aktiv. macOS baut ihn mit mdutil -E neu auf – in den Papierkorb gelegt wird nur die Suche unbrauchbar, bis er neu aufgebaut ist."],
    "diagnostics.explanation.spotlightNotIndexed": ["Spotlight's index for this volume; indexing currently reports as off. macOS manages this directory.", "此卷的 Spotlight 索引，当前索引服务处于关闭状态。此目录由 macOS 管理。", "이 볼륨의 Spotlight 색인이며 현재 색인이 꺼져 있습니다. 이 디렉터리는 macOS가 관리합니다.", "Индекс Spotlight для этого тома; индексация сейчас отключена. Каталог управляется macOS.", "Índice de Spotlight de este volumen; la indexación figura como desactivada. macOS gestiona este directorio.", "このボリュームの Spotlight インデックスで、現在は索引が無効です。このフォルダは macOS が管理します。", "Index Spotlight de ce volume ; l’indexation est signalée comme inactive. Ce dossier est géré par macOS.", "Spotlight-Index dieses Volumes; die Indizierung meldet sich als aus. Dieses Verzeichnis verwaltet macOS."],
    "diagnostics.explanation.spotlightStateUnknown": ["Spotlight's index for this volume. What Spotlight is currently doing could not be read.", "此卷的 Spotlight 索引。无法读取 Spotlight 当前的状态。", "이 볼륨의 Spotlight 색인입니다. 현재 Spotlight 상태를 읽을 수 없습니다.", "Индекс Spotlight для этого тома. Текущее состояние Spotlight прочитать не удалось.", "Índice de Spotlight de este volumen. No se pudo leer qué está haciendo Spotlight ahora mismo.", "このボリュームの Spotlight インデックスです。現在の状態を読み取れませんでした。", "Index Spotlight de ce volume. L’état actuel de Spotlight n’a pas pu être lu.", "Spotlight-Index dieses Volumes. Der aktuelle Zustand war nicht lesbar."],
    "diagnostics.explanation.spotlightUnreadable": ["Spotlight's index for this volume. Its size could not be read: Full Disk Access is required.", "此卷的 Spotlight 索引。无法读取它的大小：需要完全磁盘访问权限。", "이 볼륨의 Spotlight 색인입니다. 크기를 읽을 수 없습니다. 전체 디스크 접근 권한이 필요합니다.", "Индекс Spotlight для этого тома. Размер прочитать не удалось: нужен полный доступ к диску.", "Índice de Spotlight de este volumen. No se pudo leer su tamaño: se necesita acceso total al disco.", "このボリュームの Spotlight インデックスです。サイズを読み取れません。フルディスクアクセスが必要です。", "Index Spotlight de ce volume. Sa taille n’a pas pu être lue : l’accès complet au disque est requis.", "Spotlight-Index dieses Volumes. Die Größe war nicht lesbar: Vollzugriff auf die Festplatte ist nötig."],
    "diagnostics.explanation.coreSpotlight": ["Search metadata the system keeps for your own content, such as mail and messages. Rebuilding it can take a while, and search is incomplete until it finishes.", "系统为你的内容（邮件、信息等）保存的搜索元数据。重建可能耗时，重建期间搜索不完整。", "메일과 메시지 등 사용자 콘텐츠를 위해 시스템이 보관하는 검색 메타데이터입니다. 다시 만드는 데 시간이 걸리며, 끝날 때까지 검색이 불완전합니다.", "Метаданные поиска, которые система хранит для ваших материалов — почты и сообщений. Перестроение занимает время, до его конца поиск неполон.", "Metadatos de búsqueda que el sistema guarda para tu contenido, como correo y mensajes. Reconstruirlos tarda un rato y la búsqueda queda incompleta hasta que termina.", "メールやメッセージなど、あなたの内容のためにシステムが保持する検索メタデータです。再構築には時間がかかり、完了まで検索は不完全です。", "Métadonnées de recherche que le système conserve pour vos contenus, comme le courrier et les messages. La reconstruction prend du temps et la recherche reste incomplète jusque-là.", "Suchmetadaten, die das System für Ihre Inhalte wie Mail und Nachrichten vorhält. Der Neuaufbau dauert, bis dahin ist die Suche unvollständig."],
    "diagnostics.explanation.coreSpotlightUnreadable": ["Search metadata the system keeps for your own content. Its size could not be read: Full Disk Access is required.", "系统为你的内容保存的搜索元数据。无法读取它的大小：需要完全磁盘访问权限。", "시스템이 사용자 콘텐츠를 위해 보관하는 검색 메타데이터입니다. 크기를 읽을 수 없습니다. 전체 디스크 접근 권한이 필요합니다.", "Метаданные поиска, которые система хранит для ваших материалов. Размер прочитать не удалось: нужен полный доступ к диску.", "Metadatos de búsqueda que el sistema guarda para tu contenido. No se pudo leer su tamaño: se necesita acceso total al disco.", "あなたの内容のためにシステムが保持する検索メタデータです。サイズを読み取れません。フルディスクアクセスが必要です。", "Métadonnées de recherche conservées pour vos contenus. Leur taille n’a pas pu être lue : l’accès complet au disque est requis.", "Suchmetadaten für Ihre Inhalte. Die Größe war nicht lesbar: Vollzugriff auf die Festplatte ist nötig."],
    "diagnostics.explanation.developerIndex": ["An index a development tool built for this project. The tool rebuilds it on demand; until then, code completion and symbol search are slower.", "开发工具为此项目建立的索引。需要时该工具会重建；在重建前，代码补全和符号搜索会更慢。", "개발 도구가 이 프로젝트를 위해 만든 색인입니다. 필요할 때 도구가 다시 만들며, 그때까지 코드 완성과 심볼 검색이 느려집니다.", "Индекс, который инструмент разработки построил для проекта. Он перестроит его при необходимости; до этого автодополнение и поиск символов медленнее.", "Índice que una herramienta de desarrollo creó para este proyecto. La herramienta lo reconstruye cuando hace falta; hasta entonces el autocompletado y la búsqueda de símbolos son más lentos.", "開発ツールがこのプロジェクト用に作成した索引です。必要になればツールが再構築します。それまで補完とシンボル検索は遅くなります。", "Index qu’un outil de développement a créé pour ce projet. L’outil le reconstruit à la demande ; d’ici là, la complétion et la recherche de symboles sont plus lentes.", "Ein Index, den ein Entwicklungswerkzeug für dieses Projekt erstellt hat. Das Werkzeug baut ihn bei Bedarf neu auf; bis dahin sind Vervollständigung und Symbolsuche langsamer."],
    "diagnostics.explanation.developerData": ["Build data and caches a development tool keeps here. Sift does not judge what a project can rebuild, so nothing here is offered for removal.", "开发工具存放的构建数据和缓存。Sift 无法判断某个项目能重建什么，因此这里的内容不会被列为可删除项。", "개발 도구가 보관하는 빌드 데이터와 캐시입니다. Sift는 프로젝트가 무엇을 다시 만들 수 있는지 판단하지 않으므로 삭제 대상으로 제시하지 않습니다.", "Данные сборки и кэши, которые хранит инструмент разработки. Sift не может судить, что проект перестроит, поэтому ничего отсюда не предлагается к удалению.", "Datos de compilación y cachés que guarda una herramienta de desarrollo. Sift no juzga qué puede reconstruir un proyecto, así que no ofrece nada de aquí para eliminar.", "開発ツールが置くビルドデータとキャッシュです。Sift はプロジェクトが何を再構築できるか判断しないため、ここから削除対象として提示しません。", "Données de compilation et caches conservés par un outil de développement. Sift ne juge pas ce qu’un projet peut reconstruire et ne propose donc rien à supprimer ici.", "Build-Daten und Caches eines Entwicklungswerkzeugs. Sift beurteilt nicht, was ein Projekt neu aufbauen kann, und bietet hier nichts zum Entfernen an."],
    "diagnostics.explanation.snapshots": ["APFS local snapshots. They hold the state of the volume, macOS thins them by itself, and no per-snapshot size is reported by the system.", "APFS 本地快照。它们保存卷的状态，macOS 会自动精简，系统不提供单个快照的占用大小。", "APFS 로컬 스냅샷입니다. 볼륨 상태를 보관하며 macOS가 스스로 정리합니다. 스냅샷별 크기는 시스템이 제공하지 않습니다.", "Локальные снимки APFS. Они хранят состояние тома, macOS прореживает их сама, размер отдельного снимка система не сообщает.", "Instantáneas locales de APFS. Guardan el estado del volumen, macOS las reduce por su cuenta y el sistema no informa del tamaño de cada una.", "APFS のローカルスナップショットです。ボリュームの状態を保持し、macOS が自動的に間引きます。個別のサイズはシステムから提供されません。", "Instantanés locaux APFS. Ils conservent l’état du volume, macOS les élague lui-même, et le système ne fournit pas de taille par instantané.", "Lokale APFS-Snapshots. Sie halten den Zustand des Volumes, macOS dünnt sie selbst aus, und das System meldet keine Größe je Snapshot."],
    "diagnostics.coverage.note": ["Open System Settings to grant Full Disk Access, then run the analysis again.", "在系统设置中授予完全磁盘访问权限，然后重新运行诊断。", "시스템 설정에서 전체 디스크 접근 권한을 허용한 뒤 다시 진단하세요.", "Выдайте полный доступ к диску в Системных настройках и запустите анализ снова.", "Concede acceso total al disco en Ajustes del Sistema y vuelve a analizar.", "システム設定でフルディスクアクセスを許可し、もう一度診断してください。", "Accordez l’accès complet au disque dans les Réglages Système, puis relancez l’analyse.", "Erteilen Sie in den Systemeinstellungen Vollzugriff auf die Festplatte und starten Sie die Analyse erneut."],
    "diagnostics.section.protected": ["Protected, but large", "受保护但占用较大", "보호되지만 큰 항목", "Защищено, но много места", "Protegido pero voluminoso", "保護されているが大きい項目", "Protégé mais volumineux", "Geschützt, aber groß"],
    "diagnostics.section.rebuildable": ["Can be rebuilt", "可以重建", "다시 만들 수 있음", "Можно перестроить", "Se puede reconstruir", "再構築できるもの", "Peut être reconstruit", "Kann neu aufgebaut werden"],
    "diagnostics.section.snapshots": ["Snapshots", "快照", "스냅샷", "Снимки", "Instantáneas", "スナップショット", "Instantanés", "Snapshots"],
    "diagnostics.section.skipped": ["Could not be read", "无法读取的位置", "읽을 수 없는 위치", "Не удалось прочитать", "No se pudo leer", "読み取れなかった場所", "Non lisible", "Nicht lesbar"],
    "diagnostics.empty": ["Nothing large was found in this scope.", "在此范围内没有发现占用较大的内容。", "이 범위에서 큰 항목을 찾지 못했습니다.", "В этой области ничего крупного не найдено.", "No se encontró nada voluminoso en este alcance.", "この範囲には大きな項目はありませんでした。", "Rien de volumineux dans cette portée.", "In diesem Bereich wurde nichts Großes gefunden."],
    "diagnostics.note.approximate": ["Sizes are estimates: clones and snapshots make allocated space non-additive.", "大小是估算值：克隆和快照会使分配空间不能简单相加。", "크기는 추정값입니다. 클론과 스냅샷 때문에 할당 공간은 단순 합산이 되지 않습니다.", "Размеры приблизительны: из-за клонов и снимков выделенное место не складывается напрямую.", "Los tamaños son estimaciones: los clones y las instantáneas hacen que el espacio asignado no sea aditivo.", "サイズは推定値です。クローンやスナップショットがあるため、割り当て容量は単純に合計できません。", "Les tailles sont estimées : les clones et les instantanés rendent l’espace alloué non additif.", "Größen sind Schätzwerte: Klone und Snapshots machen belegten Speicher nicht addierbar."],
    "diagnostics.note.readOnly": ["Diagnostics only reads. Nothing here is removed, and a cleanup still goes through the normal confirmation.", "诊断只做读取。这里的任何内容都不会被删除；如要清理，仍会走正常的确认流程。", "진단은 읽기만 합니다. 여기서 아무것도 삭제되지 않으며, 정리는 평소의 확인 절차를 거칩니다.", "Диагностика только читает. Здесь ничего не удаляется, а очистка по-прежнему проходит обычное подтверждение.", "El diagnóstico solo lee. Aquí no se elimina nada y cualquier limpieza pasa por la confirmación habitual.", "診断は読み取りのみです。ここでは何も削除されず、整理する場合も通常の確認を行います。", "Le diagnostic ne fait que lire. Rien n’est supprimé ici, et un nettoyage passe toujours par la confirmation habituelle.", "Die Diagnose liest nur. Hier wird nichts entfernt, und eine Bereinigung durchläuft weiterhin die übliche Bestätigung."],

    "files.manageScope": ["Manage in Settings", "在设置中管理", "설정에서 관리", "Управлять в настройках", "Gestionar en Ajustes", "設定で管理", "Gérer dans les Réglages", "In den Einstellungen verwalten"],
    "settings.group.authorized": ["Authorised folders", "已授权文件夹", "승인된 폴더", "Разрешённые папки", "Carpetas autorizadas", "許可されたフォルダ", "Dossiers autorisés", "Autorisierte Ordner"],
    "settings.authorized.empty": ["Nothing has been authorised yet. Folders you add here are scanned, and used to find duplicates.", "尚未授权任何位置。在此添加的文件夹会被扫描，并用于查找重复文件。", "아직 승인된 위치가 없습니다. 여기에서 추가한 폴더는 검사되며 중복 파일 찾기에 사용됩니다.", "Пока ничего не разрешено. Добавленные здесь папки сканируются и используются для поиска дубликатов.", "Aún no has autorizado nada. Las carpetas que añadas aquí se analizan y se usan para buscar duplicados.", "まだ何も許可されていません。ここで追加したフォルダはスキャンされ、重複ファイルの検索に使われます。", "Rien n’est encore autorisé. Les dossiers ajoutés ici sont analysés et servent à trouver les doublons.", "Noch nichts autorisiert. Hier hinzugefügte Ordner werden gescannt und für die Duplikatsuche verwendet."],
    "settings.staleThreshold": ["Stale threshold", "过期阈值", "오래된 항목 기준", "Порог устаревания", "Umbral de antigüedad", "古い項目のしきい値", "Seuil d’ancienneté", "Schwelle für veraltete Einträge"],
    "storage.includeVolume": ["Include whole-volume diagnostics", "包含整卷诊断", "볼륨 전체 진단 포함", "Включить диагностику всего тома", "Incluir diagnóstico de todo el volumen", "ボリューム全体の診断を含める", "Inclure le diagnostic du volume entier", "Diagnose des gesamten Volumes einbeziehen"],
    "storage.scopeNote": ["File categories cover your home folder and authorised folders on this disk. The toggle adds whole-volume system diagnostics.", "文件分类统计个人文件夹和此磁盘上已授权的文件夹；开关会为系统诊断加入整卷范围。", "파일 분류는 홈과 이 디스크에서 승인한 폴더를 포함합니다. 스위치는 시스템 진단에 볼륨 전체를 포함합니다.", "Категории файлов охватывают домашнюю папку и разрешённые папки на этом диске. Переключатель добавляет диагностику всего тома.", "Las categorías cubren tu carpeta personal y las carpetas autorizadas en este disco. La opción añade el diagnóstico de todo el volumen.", "ファイル分類はホームとこのディスク上で許可したフォルダを対象にします。スイッチはシステム診断にボリューム全体を加えます。", "Les catégories couvrent votre dossier personnel et les dossiers autorisés sur ce disque. L’option ajoute le diagnostic du volume entier.", "Die Dateikategorien umfassen Ihren Benutzerordner und autorisierte Ordner auf diesem Volume. Die Option ergänzt die Systemdiagnose für das gesamte Volume."],
    "settings.authorized.unavailable": ["Not available in this session", "本次会话不可用", "이번 세션에서 사용할 수 없음", "Недоступно в этом сеансе", "No disponible en esta sesión", "このセッションでは利用できません", "Indisponible pour cette session", "In dieser Sitzung nicht verfügbar"],
    "files.scopeTitle": ["Folders you added", "你添加的文件夹", "추가한 폴더", "Добавленные папки", "Carpetas que añadiste", "追加したフォルダ", "Dossiers que vous avez ajoutés", "Von Ihnen hinzugefügte Ordner"],
    "settings.removeLicense": ["Remove stored licence key", "移除已存的许可证密钥", "저장된 라이선스 키 제거", "Удалить сохранённый лицензионный ключ", "Eliminar la clave de licencia guardada", "保存済みのライセンスキーを削除", "Supprimer la clé de licence enregistrée", "Gespeicherten Lizenzschlüssel entfernen"],
    # --- Storage -----------------------------------------------------------
    "storage.title": ["Storage", "存储", "저장 공간", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
    "storage.used": ["%@ used of %@", "已使用 %@ / %@", "%@ / %@ 사용", "Занято %@ из %@", "%@ usados de %@", "%@ / %@ 使用中", "%@ utilisés sur %@", "%@ von %@ belegt"],
    "storage.byType": ["By file type", "按类型", "파일 유형별", "По типу файлов", "Por tipo de archivo", "ファイルの種類別", "Par type de fichier", "Nach Dateityp"],
    "storage.type.images": ["Images", "图像", "이미지", "Изображения", "Imágenes", "画像", "Images", "Bilder"],
    "storage.type.video": ["Video", "视频", "동영상", "Видео", "Vídeo", "動画", "Vidéo", "Videos"],
    "storage.type.audio": ["Audio", "音频", "오디오", "Аудио", "Audio", "オーディオ", "Audio", "Audio"],
    "storage.type.documents": ["Documents", "文档", "문서", "Документы", "Documentos", "書類", "Documents", "Dokumente"],
    "storage.type.archives": ["Archives", "压缩包", "압축 파일", "Архивы", "Archivos comprimidos", "アーカイブ", "Archives", "Archive"],
    "storage.type.code": ["Code", "代码", "코드", "Код", "Código", "コード", "Code", "Code"],
    "storage.type.data": ["Data", "数据", "데이터", "Данные", "Datos", "データ", "Données", "Daten"],
    "storage.type.other": ["Other", "其他", "기타", "Другое", "Otros", "その他", "Autre", "Andere"],
    "storage.topFiles": ["Largest files", "最大文件", "큰 파일 순위", "Самые большие файлы", "Archivos más grandes", "大きいファイル順", "Fichiers les plus volumineux", "Größte Dateien"],
    "storage.topDirectories": ["Largest folders", "最大目录", "큰 폴더 순위", "Самые большие папки", "Carpetas más grandes", "大きいフォルダ順", "Dossiers les plus volumineux", "Größte Ordner"],
    "storage.analyze": ["Analyze storage", "分析存储", "저장 공간 분석", "Анализировать хранилище", "Analizar almacenamiento", "ストレージを分析", "Analyser le stockage", "Speicher analysieren"],
    "storage.start": ["Start analysis", "开始分析", "분석 시작", "Начать анализ", "Iniciar análisis", "分析を開始", "Lancer l’analyse", "Analyse starten"],
    "storage.reanalyze": ["Analyze again", "重新分析", "다시 분석", "Повторить анализ", "Analizar de nuevo", "再分析", "Réanalyser", "Erneut analysieren"],
    "storage.cancelAnalysis": ["Cancel analysis", "取消分析", "분석 취소", "Отменить анализ", "Cancelar análisis", "分析を中止", "Annuler l’analyse", "Analyse abbrechen"],
    "storage.lastAnalyzed": ["Last analysed %@", "上次分析：%@", "마지막 분석: %@", "Последний анализ: %@", "Último análisis: %@", "前回の分析: %@", "Dernière analyse : %@", "Zuletzt analysiert: %@"],
    "storage.analysing": ["Analyzing…", "分析中…", "분석 중…", "Анализ…", "Analizando…", "分析中…", "Analyse…", "Analyse läuft…"],
    "storage.diskDisconnected": [
        "This disk is no longer connected. Reconnect it and scan again.",
        "此磁盘已断开连接。请重新连接后再扫描。",
        "이 디스크의 연결이 끊어졌습니다. 다시 연결한 뒤 검사하세요.",
        "Этот диск отключён. Подключите его снова и повторите.",
        "Este disco ya no está conectado. Vuelve a conectarlo y analiza de nuevo.",
        "このディスクは接続されていません。再接続してスキャンしてください。",
        "Ce disque n’est plus connecté. Reconnectez-le puis relancez.",
        "Dieses Laufwerk ist nicht mehr verbunden. Bitte erneut anschließen.",
    ],
    "storage.noAccess": ["Sift cannot read this location yet.", "Sift 还无法读取此位置。", "Sift가 아직 이 위치를 읽을 수 없습니다.", "Sift пока не может прочитать это место.", "Sift aún no puede leer esta ubicación.", "この場所はまだ読み取れません。", "Sift ne peut pas encore lire cet emplacement.", "Sift kann diesen Ort noch nicht lesen."],

    # --- Settings ----------------------------------------------------------
    "settings.title": ["Settings", "设置", "설정", "Настройки", "Ajustes", "設定", "Réglages", "Einstellungen"],
    "settings.group.scanScope": ["Scan scope", "扫描范围", "검사 범위", "Область сканирования", "Alcance del análisis", "スキャン範囲", "Portée de l’analyse", "Scanbereich"],
    "settings.group.thresholds": ["Thresholds", "阈值", "기준값", "Пороги", "Umbrales", "しきい値", "Seuils", "Schwellenwerte"],
    "settings.group.ignores": ["Ignored items", "忽略列表", "무시 목록", "Исключения", "Elementos ignorados", "無視リスト", "Éléments ignorés", "Ignorierte Einträge"],
    "settings.group.confirmation": ["Confirmation", "确认", "확인", "Подтверждение", "Confirmación", "確認", "Confirmation", "Bestätigung"],
    "settings.group.appearance": ["Appearance", "外观", "모양", "Оформление", "Apariencia", "外観", "Apparence", "Erscheinungsbild"],
    "settings.group.language": ["Language", "语言", "언어", "Язык", "Idioma", "言語", "Langue", "Sprache"],
    "settings.group.privacy": ["Privacy", "隐私说明", "개인정보", "Конфиденциальность", "Privacidad", "プライバシー", "Confidentialité", "Datenschutz"],
    "settings.group.purchase": ["Purchase", "购买状态", "구매", "Покупка", "Compra", "購入", "Achat", "Kauf"],
    "settings.group.logs": ["Diagnostics", "日志", "진단", "Диагностика", "Diagnósticos", "診断", "Diagnostic", "Diagnose"],
    "settings.largeFileThreshold": ["Large file threshold", "大文件阈值", "큰 파일 기준", "Порог больших файлов", "Umbral de archivos grandes", "大きいファイルの基準", "Seuil des fichiers volumineux", "Schwelle für große Dateien"],
    "settings.oldFileThreshold": ["Old file threshold", "旧文件阈值", "오래된 파일 기준", "Порог старых файлов", "Umbral de archivos antiguos", "古いファイルの基準", "Seuil des fichiers anciens", "Schwelle für alte Dateien"],
    "settings.days": ["%d days", "%d 天", "%d일", "%d дней", "%d días", "%d 日", "%d jours", "%d Tage"],
    "settings.showHiddenFiles": ["Show hidden files in results", "结果显示隐藏文件", "결과에 숨김 파일 표시", "Показывать скрытые файлы", "Mostrar archivos ocultos", "隠しファイルを表示", "Afficher les fichiers cachés", "Versteckte Dateien anzeigen"],
    "settings.userRules": ["Use a custom rule file", "使用自定义规则文件", "사용자 규칙 파일 사용", "Использовать файл правил", "Usar un archivo de reglas", "カスタムルールファイルを使用", "Utiliser un fichier de règles", "Eigene Regeldatei verwenden"],
    "settings.userRulesDetail": ["Reads CleaningRules.json from the app's data folder. Applies to the next scan.", "从应用数据目录读取 CleaningRules.json，下一次扫描生效。", "앱 데이터 폴더의 CleaningRules.json을 읽습니다. 다음 검사부터 적용됩니다.", "Читает CleaningRules.json из папки данных приложения. Применяется со следующего сканирования.", "Lee CleaningRules.json de la carpeta de datos de la app. Se aplica al próximo análisis.", "アプリのデータフォルダの CleaningRules.json を読み込みます。次回のスキャンから適用されます。", "Lit CleaningRules.json dans le dossier de données de l’app. S’applique au prochain scan.", "Liest CleaningRules.json aus dem Datenordner der App. Gilt ab dem nächsten Scan."],
    "settings.requireConfirmation": ["Ask for confirmation before cleaning", "清理前要求确认", "정리 전 확인", "Спрашивать перед очисткой", "Pedir confirmación antes de limpiar", "削除前に確認する", "Demander confirmation avant nettoyage", "Vor dem Bereinigen bestätigen"],
    "settings.skipConfirmation": ["Skip confirmation", "跳过确认", "확인 건너뛰기", "Пропускать подтверждение", "Omitir confirmación", "確認をスキップ", "Ignorer la confirmation", "Bestätigung überspringen"],
    "settings.skipConfirmationWarning": [
        "Sift cleans as soon as you click. Items still go to the Trash, but you will not see the list first. Items marked for review always show the list.",
        "点击后 Sift 会立即开始清理。项目仍会进入废纸篓，但不会先显示清单。标记为需确认的项目始终会显示清单。",
        "클릭하면 Sift가 바로 정리를 시작합니다. 항목은 휴지통으로 이동하지만 목록을 먼저 보지 못합니다. 확인이 필요한 항목은 항상 목록을 표시합니다.",
        "Sift начнёт очистку сразу после нажатия. Объекты всё равно попадут в Корзину, но список вы не увидите. Объекты, требующие проверки, всегда показывают список.",
        "Sift limpia en cuanto haces clic. Los elementos van a la papelera, pero no verás la lista antes. Los elementos marcados para revisar siempre muestran la lista.",
        "クリックすると Sift はすぐに整理を始めます。項目はゴミ箱に移動しますが、一覧は先に表示されません。確認が必要な項目は常に一覧を表示します。",
        "Sift nettoie dès que vous cliquez. Les éléments vont dans la corbeille, mais vous ne verrez pas la liste d’abord. Les éléments à vérifier affichent toujours la liste.",
        "Sift bereinigt sofort nach dem Klick. Objekte landen weiterhin im Papierkorb, die Liste sehen Sie aber nicht vorab. Objekte, die geprüft werden müssen, zeigen die Liste immer.",
    ],
    "settings.appearance.system": ["Follow system", "跟随系统", "시스템 설정 따르기", "Как в системе", "Según el sistema", "システムに従う", "Suivre le système", "Systemeinstellung"],
    "settings.appearance.light": ["Light", "浅色", "라이트", "Светлое", "Claro", "ライト", "Clair", "Hell"],
    "settings.appearance.dark": ["Dark", "深色", "다크", "Тёмное", "Oscuro", "ダーク", "Sombre", "Dunkel"],
    "settings.reduceMotion": ["Reduce motion", "减少动态效果", "동작 줄이기", "Уменьшить движение", "Reducir movimiento", "視差効果を減らす", "Réduire les animations", "Bewegung reduzieren"],
    "settings.privacyStatement": [
        "Sift does not collect file contents, file names, full paths, browsing history, app usage or account details. Scan results stay on this Mac, and nothing is uploaded.",
        "Sift 不采集文件内容、文件名、完整路径、浏览历史、应用使用记录或账号信息。扫描结果只保存在本机，不会上传。",
        "Sift는 파일 내용, 파일 이름, 전체 경로, 방문 기록, 앱 사용 기록 또는 계정 정보를 수집하지 않습니다. 검사 결과는 이 Mac에만 남습니다.",
        "Sift не собирает содержимое файлов, имена, полные пути, историю браузера, данные об использовании приложений или аккаунт. Результаты остаются на этом Mac.",
        "Sift no recopila contenidos, nombres de archivo, rutas completas, historial de navegación, uso de apps ni datos de cuenta. Los resultados se quedan en este Mac.",
        "Sift はファイル内容、ファイル名、完全なパス、閲覧履歴、アプリの使用履歴、アカウント情報を収集しません。結果はこの Mac にのみ保存されます。",
        "Sift ne collecte ni contenu, ni noms de fichiers, ni chemins complets, ni historique, ni usage des apps, ni données de compte. Les résultats restent sur ce Mac.",
        "Sift erfasst keine Dateiinhalte, Dateinamen, vollständigen Pfade, Verläufe, App-Nutzung oder Kontodaten. Ergebnisse bleiben auf diesem Mac.",
    ],
    "settings.exportLogs": ["Export diagnostics", "导出日志", "진단 내보내기", "Экспорт диагностики", "Exportar diagnósticos", "診断情報を書き出す", "Exporter les diagnostics", "Diagnose exportieren"],
    "settings.exportLogsDetail": [
        "Diagnostics contain no file names or full paths.",
        "诊断日志不包含文件名或完整路径。",
        "진단 로그에는 파일 이름이나 전체 경로가 없습니다.",
        "Диагностика не содержит имён файлов или полных путей.",
        "Los diagnósticos no contienen nombres ni rutas completas.",
        "診断情報にファイル名や完全なパスは含まれません。",
        "Les diagnostics ne contiennent ni noms ni chemins complets.",
        "Diagnosedaten enthalten keine Dateinamen oder vollständigen Pfade.",
    ],
    "settings.clearHistory": ["Clear scan history", "清除扫描历史", "검사 기록 지우기", "Очистить историю сканирований", "Borrar historial de análisis", "スキャン履歴を消去", "Effacer l’historique", "Scan-Verlauf löschen"],
    "settings.deleteReports": ["Delete saved reports", "删除已保存的报告", "저장된 보고서 삭제", "Удалить сохранённые отчёты", "Eliminar informes guardados", "保存されたレポートを削除", "Supprimer les rapports enregistrés", "Gespeicherte Berichte löschen"],
    "settings.deleteReportsConfirm": [
        "Delete all saved PDF reports? This cannot be undone.",
        "删除所有已保存的 PDF 报告？此操作无法撤销。",
        "저장된 모든 PDF 보고서를 삭제할까요? 이 작업은 되돌릴 수 없습니다.",
        "Удалить все сохранённые PDF-отчёты? Это действие нельзя отменить.",
        "¿Eliminar todos los informes PDF guardados? Esta acción no se puede deshacer.",
        "保存されているすべての PDF レポートを削除しますか？この操作は取り消せません。",
        "Supprimer tous les rapports PDF enregistrés ? Cette action est irréversible.",
        "Alle gespeicherten PDF-Berichte löschen? Dies kann nicht rückgängig gemacht werden.",
    ],
    "settings.resetDefaults": ["Restore defaults", "恢复默认设置", "기본값 복원", "Восстановить значения по умолчанию", "Restaurar valores", "既定値に戻す", "Rétablir les réglages", "Standard wiederherstellen"],

    # --- Purchase ----------------------------------------------------------
    "purchase.title": ["Unlock Sift", "解锁 Sift", "Sift 잠금 해제", "Разблокировать Sift", "Desbloquear Sift", "Sift をアンロック", "Débloquer Sift", "Sift freischalten"],
    "purchase.priceLine": [
        "$4.99 once, yours forever, no subscription",
        "$4.99 一次性买断，永久使用，无订阅",
        "$4.99 한 번 구매로 영구 사용, 구독 없음",
        "$4.99 единоразово, навсегда, без подписки",
        "$4.99 una vez, para siempre, sin suscripción",
        "$4.99 の買い切り、ずっと使えてサブスクなし",
        "4,99 $ une fois, à vie, sans abonnement",
        "4,99 $ einmalig, dauerhaft, kein Abo",
    ],
    "purchase.updatesPromise": [
        "Includes future major updates.",
        "包含未来大版本更新。",
        "향후 주요 업데이트 포함.",
        "Включает будущие крупные обновления.",
        "Incluye futuras actualizaciones importantes.",
        "今後のメジャーアップデートを含みます。",
        "Inclut les futures versions majeures.",
        "Enthält künftige Hauptversionen.",
    ],
    "purchase.freeTier.scan": ["Scan your whole Mac", "扫描整台 Mac", "Mac 전체 검사", "Сканировать весь Mac", "Analizar todo tu Mac", "Mac 全体をスキャン", "Analyser tout votre Mac", "Den ganzen Mac scannen"],
    "purchase.freeTier.explain": ["See every item, its source and its risk", "查看每个项目的来源和风险", "모든 항목의 출처와 위험도 확인", "Видеть каждый элемент, источник и риск", "Ver cada elemento, su origen y su riesgo", "各項目の由来とリスクを確認", "Voir chaque élément, son origine et son risque", "Jeden Eintrag mit Quelle und Risiko sehen"],
    "purchase.freeTier.estimate": ["See how much space you could release", "查看可释放空间估算", "확보 가능한 공간 확인", "Оценить освобождаемое место", "Ver cuánto espacio podrías liberar", "解放できる容量の推定を見る", "Voir l’espace récupérable", "Sehen, wie viel frei wird"],
    "purchase.freeTier.storage": ["Analyze storage by type and folder", "按类型和目录分析存储", "유형 및 폴더별 분석", "Анализ хранилища по типам и папкам", "Analizar por tipo y carpeta", "種類とフォルダ別に分析", "Analyser par type et dossier", "Nach Typ und Ordner analysieren"],
    "purchase.paidTierTitle": ["What unlocking adds", "解锁后新增", "잠금 해제 시 추가", "Что даёт разблокировка", "Lo que añade el desbloqueo", "アンロックで追加される機能", "Ce que le déblocage ajoute", "Was die Freischaltung bringt"],
    "purchase.paidTier.clean": ["Move caches, logs and installers to Trash", "将缓存、日志和安装包移入废纸篓", "캐시, 로그, 설치 파일을 휴지통으로 이동", "Переместить кэши, логи и установщики в Корзину", "Mover cachés, registros e instaladores a la papelera", "キャッシュ、ログ、インストーラをゴミ箱へ", "Déplacer caches, journaux et installateurs à la corbeille", "Caches, Protokolle und Installer in den Papierkorb"],
    "purchase.paidTier.uninstall": ["Uninstall apps with their related files", "连同关联文件卸载应用", "관련 파일과 함께 앱 제거", "Удалять приложения вместе со связанными файлами", "Desinstalar apps con sus archivos", "関連ファイルごとアプリを削除", "Désinstaller les apps avec leurs fichiers", "Apps samt zugehörigen Dateien entfernen"],
    "purchase.paidTier.files": ["Clean large, old and duplicate files", "清理大文件、旧文件和重复文件", "큰 파일, 오래된 파일, 중복 파일 정리", "Чистить большие, старые и дублирующие файлы", "Limpiar archivos grandes, antiguos y duplicados", "大きい・古い・重複ファイルを整理", "Nettoyer les fichiers volumineux, anciens et doublons", "Große, alte und doppelte Dateien bereinigen"],
    "purchase.paidTier.report": ["Full cleanup reports and PDF export", "完整清理报告和 PDF 导出", "전체 정리 보고서 및 PDF 내보내기", "Полные отчёты и экспорт в PDF", "Informes completos y exportación a PDF", "完全なレポートと PDF 書き出し", "Rapports complets et export PDF", "Vollständige Berichte und PDF-Export"],
    "purchase.activateLicense": ["Enter license key", "输入授权码", "라이선스 키 입력", "Ввести лицензионный ключ", "Introducir clave de licencia", "ライセンスキーを入力", "Saisir la clé de licence", "Lizenzschlüssel eingeben"],
    "purchase.restore": ["Restore purchase", "恢复购买", "구매 복원", "Восстановить покупку", "Restaurar compra", "購入を復元", "Restaurer l’achat", "Kauf wiederherstellen"],
    "purchase.restored": ["Purchase restored. Cleaning is unlocked.", "已恢复购买。清理功能已解锁。", "구매를 복원했습니다. 정리 기능이 열렸습니다.", "Покупка восстановлена. Очистка доступна.", "Compra restaurada. La limpieza está desbloqueada.", "購入を復元しました。クリーンアップが利用できます。", "Achat restauré. Le nettoyage est débloqué.", "Kauf wiederhergestellt. Bereinigung ist frei."],
    "purchase.activated": ["License activated. Thank you!", "授权已激活，谢谢！", "라이선스가 활성화되었습니다. 감사합니다!", "Лицензия активирована. Спасибо!", "Licencia activada. ¡Gracias!", "ライセンスを有効化しました。ありがとうございます。", "Licence activée. Merci !", "Lizenz aktiviert. Danke!"],
    "purchase.failed": ["We could not complete that. Please try again.", "操作未能完成，请重试。", "완료하지 못했습니다. 다시 시도해 주세요.", "Не удалось завершить. Повторите попытку.", "No se pudo completar. Inténtalo de nuevo.", "完了できませんでした。もう一度お試しください。", "Impossible de terminer. Réessayez.", "Vorgang nicht abgeschlossen. Bitte erneut versuchen."],
    "purchase.networkUnavailable": [
        "The purchase service could not be reached. Your license stays usable offline for now.",
        "无法连接购买服务。你的授权目前仍可离线使用。",
        "구매 서비스에 연결할 수 없습니다. 라이선스는 당분간 오프라인에서 사용할 수 있습니다.",
        "Сервис покупки недоступен. Лицензия пока работает офлайн.",
        "No se pudo contactar con el servicio. Tu licencia sigue funcionando sin conexión.",
        "購入サービスに接続できません。ライセンスはしばらくオフラインで利用できます。",
        "Service d’achat injoignable. Votre licence reste utilisable hors ligne.",
        "Kaufdienst nicht erreichbar. Ihre Lizenz bleibt vorerst offline nutzbar.",
    ],
    "purchase.licenseRequired": ["Unlock Sift to clean", "解锁 Sift 以执行清理", "정리하려면 Sift 잠금 해제", "Разблокируйте Sift для очистки", "Desbloquea Sift para limpiar", "クリーニングにはアンロックが必要", "Débloquez Sift pour nettoyer", "Sift freischalten, um zu bereinigen"],
    "purchase.licenseRequiredDetail": [
        "Scanning, analysis and previews stay free. Cleaning and uninstalling need the one-time purchase.",
        "扫描、分析和预览始终免费。清理和卸载需要一次性购买。",
        "스캔, 분석, 미리보기는 무료입니다. 정리와 제거에는 한 번 구매가 필요합니다.",
        "Сканирование, анализ и предпросмотр бесплатны. Очистка и удаление требуют покупки.",
        "Escanear, analizar y previsualizar es gratis. Limpiar y desinstalar requiere la compra.",
        "スキャン・分析・プレビューは無料です。削除とアンインストールには買い切り購入が必要です。",
        "Analyse et aperçu gratuits. Nettoyage et désinstallation nécessitent l’achat.",
        "Scannen, Analyse und Vorschau bleiben gratis. Bereinigen und Deinstallieren kosten einmalig.",
    ],
    "purchase.offlineGrace": ["Offline grace period: %d days left", "离线宽限期还剩 %d 天", "오프라인 유예 기간 %d일 남음", "Офлайн-период: осталось %d дней", "Periodo sin conexión: %d días", "オフライン猶予は残り %d 日", "Période hors ligne : %d jours restants", "Offline-Kulanz: noch %d Tage"],
    "purchase.status.purchased": ["Purchased", "已购买", "구매 완료", "Куплено", "Comprado", "購入済み", "Acheté", "Gekauft"],
    "purchase.status.free": ["Free version", "免费版", "무료 버전", "Бесплатная версия", "Versión gratuita", "無料版", "Version gratuite", "Kostenlose Version"],

    # --- Account ------------------------------------------------------------
    "nav.account": ["Account", "账户", "계정", "Аккаунт", "Cuenta", "アカウント", "Compte", "Konto"],
    "account.activatedAt": ["Activated", "激活时间", "활성화 날짜", "Дата активации", "Fecha de activación", "アクティベート日", "Date d’activation", "Aktiviert am"],
    "account.licenseKey": ["License key", "授权码", "라이선스 키", "Лицензионный ключ", "Clave de licencia", "ライセンスキー", "Clé de licence", "Lizenzschlüssel"],

    # --- Report ------------------------------------------------------------
    "report.title": ["Cleanup report", "清理报告", "정리 보고서", "Отчёт об очистке", "Informe de limpieza", "クリーンアップレポート", "Rapport de nettoyage", "Bereinigungsbericht"],
    "report.generatedAt": ["Generated %@", "生成时间 %@", "생성 시각 %@", "Создано %@", "Generado el %@", "作成日時 %@", "Généré le %@", "Erstellt am %@"],
    "report.appVersion": ["Sift %@ on macOS %@", "Sift %@，macOS %@", "Sift %@ / macOS %@", "Sift %@, macOS %@", "Sift %@ en macOS %@", "Sift %@ / macOS %@", "Sift %@ sur macOS %@", "Sift %@ unter macOS %@"],
    "report.scope": ["What was scanned", "扫描范围摘要", "검사 범위", "Что сканировалось", "Qué se analizó", "スキャン対象", "Portée de l’analyse", "Gescannter Bereich"],
    "report.scopeDetail": [
        "%d locations, %d files examined",
        "%d 个位置，检查 %d 个文件",
        "%d개 위치, %d개 파일 검사",
        "Мест: %d, проверено файлов: %d",
        "%d ubicaciones, %d archivos examinados",
        "%d 箇所、%d ファイルを確認",
        "%d emplacements, %d fichiers examinés",
        "%d Orte, %d Dateien geprüft",
    ],
    "report.categories": ["Categories handled", "处理的分类", "처리한 카테고리", "Обработанные категории", "Categorías tratadas", "処理したカテゴリ", "Catégories traitées", "Bearbeitete Kategorien"],
    "report.status": ["Status", "状态", "상태", "Статус", "Estado", "状態", "Statut", "Status"],
    "report.status.moved": ["Moved to Trash", "已移入废纸篓", "휴지통으로 이동됨", "Перемещено в Корзину", "Movido a la papelera", "ゴミ箱へ移動済み", "Déplacé vers la corbeille", "In den Papierkorb verschoben"],
    "report.status.skipped": ["Skipped", "已跳过", "건너뜀", "Пропущено", "Omitido", "スキップ", "Ignoré", "Übersprungen"],
    "report.status.failed": ["Failed", "未完成", "완료되지 않음", "Не выполнено", "Sin completar", "未完了", "Non terminé", "Nicht abgeschlossen"],
    "report.moved": ["Moved to Trash", "成功移入废纸篓", "휴지통으로 이동", "Перемещено в Корзину", "Movido a la papelera", "ゴミ箱へ移動", "Déplacé vers la corbeille", "In den Papierkorb verschoben"],
    "report.movedDetail": ["%d items, %@", "%d 个项目，%@", "%d개 항목, %@", "Элементов: %d, %@", "%d elementos, %@", "%d 項目、%@", "%d éléments, %@", "%d Einträge, %@"],
    "report.released": ["Space released", "预计释放空间", "확보한 공간", "Освобождено места", "Espacio liberado", "解放した容量", "Espace libéré", "Freigegebener Speicher"],
    "report.skipped": ["Skipped", "跳过项目", "건너뛴 항목", "Пропущено", "Omitidos", "スキップ", "Ignorés", "Übersprungen"],
    "report.skippedDetail": ["Skipped %d items. Showing the first 20.", "跳过 %d 个项目，最多列出前 20 个。", "%d개 항목을 건너뛰었습니다. 처음 20개만 표시합니다.", "Пропущено элементов: %d. Показаны первые 20.", "Se omitieron %d elementos. Se muestran los primeros 20.", "%d 項目をスキップしました。最初の 20 件を表示します。", "%d éléments ignorés. Les 20 premiers sont affichés.", "%d Einträge übersprungen. Die ersten 20 werden gezeigt."],
    "report.failed": ["Not completed", "未完成项目", "완료되지 않은 항목", "Не выполнено", "Sin completar", "未完了", "Non terminé", "Nicht abgeschlossen"],
    "report.failedDetail": ["%d items, see details below", "%d 个项目，详见下方", "%d개 항목, 아래 세부 정보 참조", "Элементов: %d, подробности ниже", "%d elementos, ver detalles abajo", "%d 項目、詳細は下記", "%d éléments, voir ci-dessous", "%d Einträge, Details unten"],
    "report.privacyNote": [
        "This report lists categories and sizes only. It contains no file names, paths or file contents.",
        "本报告只列出分类和大小，不包含文件名、路径或文件内容。",
        "이 보고서는 카테고리와 크기만 표시하며 파일 이름, 경로, 내용을 포함하지 않습니다.",
        "В отчёте только категории и размеры: без имён файлов, путей и содержимого.",
        "Este informe solo lista categorías y tamaños: sin nombres, rutas ni contenidos.",
        "このレポートは分類と容量のみです。ファイル名やパス、内容は含みません。",
        "Ce rapport ne liste que des catégories et des tailles : aucun nom, chemin ni contenu.",
        "Dieser Bericht nennt nur Kategorien und Größen: keine Dateinamen, Pfade oder Inhalte.",
    ],
    "report.exportFailed": [
        "The report could not be saved. It is still kept locally, so you can try again.",
        "报告保存失败。本地报告仍然保留，可以重试。",
        "보고서를 저장하지 못했습니다. 로컬 사본은 남아 있으니 다시 시도할 수 있습니다.",
        "Не удалось сохранить отчёт. Локальная копия сохранена, можно повторить.",
        "No se pudo guardar el informe. La copia local sigue disponible para reintentar.",
        "レポートを保存できませんでした。ローカルに残っているため再試行できます。",
        "Le rapport n’a pas pu être enregistré. La copie locale permet de réessayer.",
        "Der Bericht konnte nicht gespeichert werden. Lokal bleibt er erhalten.",
    ],

    # --- Permissions -------------------------------------------------------
    "permission.fullDiskAccess": ["Full Disk Access", "完全磁盘访问权限", "전체 디스크 접근 권한", "Полный доступ к диску", "Acceso total al disco", "フルディスクアクセス", "Accès complet au disque", "Vollständiger Festplattenzugriff"],
    "permission.fullDiskAccessDetail": [
        "Sift scans caches and logs without it. Granting Full Disk Access lets it also read system logs and app support folders.",
        "Sift 无需该权限也能扫描缓存和日志。授予完全磁盘访问权限后，还可读取系统日志和应用支持目录。",
        "Sift는 이 권한 없이도 캐시와 로그를 검사합니다. 허용하면 시스템 로그와 앱 지원 폴더도 읽습니다.",
        "Sift сканирует кэши и логи и без него. С ним также читаются системные логи и папки приложений.",
        "Sift analiza cachés y registros sin ello. Concediéndolo, también lee registros del sistema y carpetas de apps.",
        "この権限がなくてもキャッシュとログはスキャンできます。許可するとシステムログやアプリのサポートフォルダも読めます。",
        "Sift analyse caches et journaux sans lui. Accordé, il lit aussi les journaux système et les dossiers d’apps.",
        "Sift scannt Caches und Protokolle auch ohne. Mit ihm liest es zusätzlich Systemprotokolle und App-Ordner.",
    ],
    "permission.partialAccess": ["Some locations could not be read", "部分位置无法访问", "일부 위치를 읽을 수 없습니다", "Некоторые места недоступны", "Algunas ubicaciones no se pudieron leer", "一部の場所を読み取れません", "Certains emplacements illisibles", "Einige Orte nicht lesbar"],
    "permission.openSettings": ["Open System Settings", "打开系统设置", "시스템 설정 열기", "Открыть Системные настройки", "Abrir Ajustes del Sistema", "システム設定を開く", "Ouvrir les Réglages", "Systemeinstellungen öffnen"],
    "permission.grantLater": ["Continue without it", "暂不授权，继续", "나중에 허용", "Продолжить без него", "Continuar sin ella", "後で許可", "Continuer sans", "Ohne fortfahren"],

    "settings.diagnostics.scannerCore": ["Scanner core", "扫描核心", "스캔 코어", "Ядро сканирования", "Núcleo de análisis", "スキャンコア", "Moteur d’analyse", "Scan-Kern"],
    "settings.diagnostics.version": ["Version", "版本", "버전", "Версия", "Versión", "バージョン", "Version", "Version"],
    "settings.diagnostics.macOS": ["macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS"],

    # --- Common ------------------------------------------------------------
    "common.done": ["Done", "完成", "완료", "Готово", "Hecho", "完了", "Terminé", "Fertig"],
    "common.close": ["Close", "关闭", "닫기", "Закрыть", "Cerrar", "閉じる", "Fermer", "Schließen"],
    "common.remove": ["Remove", "移除", "제거", "Удалить", "Eliminar", "削除", "Supprimer", "Entfernen"],
    "common.unknownError": ["That didn't work. Try again.", "操作失败，请重试。", "작업을 마치지 못했습니다. 다시 시도해 주세요.", "Не получилось. Повторите попытку.", "No ha funcionado. Inténtalo de nuevo.", "操作できませんでした。もう一度お試しください。", "Cela n’a pas fonctionné. Réessayez.", "Das hat nicht funktioniert. Bitte erneut versuchen."],
    "common.fileCount": ["%d files", "%d 个文件", "%d개 파일", "Файлов: %d", "%d archivos", "%d 個のファイル", "%d fichiers", "%d Dateien"],
    "common.itemCount": ["%d items", "%d 个项目", "%d개 항목", "Элементов: %d", "%d elementos", "%d 項目", "%d éléments", "%d Einträge"],
    "common.notAvailable": ["Not available", "不可用", "사용할 수 없음", "Недоступно", "No disponible", "利用できません", "Indisponible", "Nicht verfügbar"],
    "common.loadMore": ["Load more", "加载更多", "더 불러오기", "Показать ещё", "Cargar más", "さらに読み込む", "Afficher plus", "Mehr laden"],
    "common.retry": ["Try again", "重试", "다시 시도", "Повторить", "Reintentar", "再試行", "Réessayer", "Erneut versuchen"],
    "common.of": ["%@ of %@", "%@ / %@", "%@ / %@", "%@ из %@", "%@ de %@", "%@ / %@", "%@ sur %@", "%@ von %@"],
    "common.size": ["Size", "大小", "크기", "Размер", "Tamaño", "サイズ", "Taille", "Größe"],
    "common.risk": ["Risk", "风险等级", "위험도", "Риск", "Riesgo", "リスク", "Risque", "Risiko"],
    "common.quitApp": ["Quit app", "退出应用", "앱 종료", "Закрыть приложение", "Cerrar app", "アプリを終了", "Quitter l’app", "App beenden"],
    "common.loading": ["Loading…", "加载中…", "불러오는 중…", "Загрузка…", "Cargando…", "読み込み中…", "Chargement…", "Wird geladen…"],
    "common.sortBy": ["Sort by", "排序方式", "정렬 기준", "Сортировать по", "Ordenar por", "並べ替え", "Trier par", "Sortieren nach"],
    # --- Redesigned navigation, overview, scan, apps and storage -----------
    "nav.scan": ["Scan", "扫描", "스캔", "Сканирование", "Analizar", "スキャン", "Analyse", "Scan"],
    "nav.apps": ["Apps", "应用", "앱", "Приложения", "Apps", "アプリ", "Apps", "Apps"],

    "overview.scanScope": ["What a scan covers", "可扫描的内容", "검사 대상", "Что охватывает сканирование", "Qué cubre el análisis", "スキャンの対象", "Ce que couvre l’analyse", "Was ein Scan abdeckt"],
    "overview.status": ["%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@"],
    "overview.reclaimable.title": ["Safe to release", "本次可安全释放", "안전하게 확보 가능", "Можно безопасно освободить", "Se puede liberar", "安全に解放できる容量", "Libérable sans risque", "Sicher freigebbar"],
    "overview.reclaimable.breakdown": ["%@ is safe, %@ needs your confirmation", "其中 %@ 为安全项，%@ 需要你确认后清理", "이 중 %@은 안전하고, %@은 확인 후 정리할 수 있습니다", "Из них %@ безопасно, %@ требует подтверждения", "De ellos, %@ es seguro y %@ requiere confirmación", "うち %@ は安全、%@ は確認後に削除できます", "Dont %@ sans risque, %@ à confirmer", "%@ sind sicher, %@ brauchen Ihre Bestätigung"],
    "overview.reclaimable.meta": ["%d categories, %d items", "%d 类，%d 项", "%d개 카테고리, %d개 항목", "Категорий: %d, элементов: %d", "%d categorías, %d elementos", "%d カテゴリ，%d 項目", "%d catégories, %d éléments", "%d Kategorien, %d Einträge"],
    "overview.ready": ["Ready to scan", "准备就绪", "검사 준비 완료", "Готово к сканированию", "Listo para analizar", "スキャンの準備完了", "Prêt à analyser", "Bereit zum Scannen"],
    "overview.noResults": ["Run a scan to see what can be safely released.", "扫描后，这里会显示可以安全释放的空间。", "검사를 실행하면 안전하게 확보할 수 있는 공간이 표시됩니다.", "Запустите сканирование, чтобы увидеть, сколько можно безопасно освободить.", "Ejecuta un análisis para ver cuánto se puede liberar.", "スキャンすると、安全に解放できる容量が表示されます。", "Lancez une analyse pour voir ce qui peut être libéré.", "Starten Sie einen Scan, um zu sehen, was sicher freigegeben werden kann."],
    "overview.viewProgress": ["View scan progress", "查看扫描进度", "검사 진행 상황 보기", "Открыть ход сканирования", "Ver progreso del análisis", "スキャンの進行状況を見る", "Voir la progression", "Scan-Fortschritt ansehen"],
    "overview.noCleanup": ["No cleanup yet", "还没有清理记录", "아직 정리 기록 없음", "Очисток ещё не было", "Aún no hay limpiezas", "クリーンアップ履歴なし", "Aucun nettoyage", "Noch keine Bereinigung"],
    "overview.cleanupHistoryHint": ["Cleanup history appears here.", "清理记录会显示在这里。", "정리 기록이 여기에 표시됩니다.", "Здесь появится история очисток.", "El historial de limpiezas aparecerá aquí.", "クリーンアップ履歴がここに表示されます。", "L’historique des nettoyages apparaîtra ici.", "Der Bereinigungsverlauf erscheint hier."],
    "overview.viewResults": ["View scan results", "查看扫描结果", "검사 결과 보기", "Открыть результаты", "Ver resultados", "スキャン結果を見る", "Voir les résultats", "Scan-Ergebnisse"],
    "overview.localOnly": ["The scan runs entirely on this Mac.", "扫描全程在本机完成", "검사는 전부 이 Mac에서 실행됩니다.", "Сканирование выполняется только на этом Mac.", "El análisis se ejecuta por completo en este Mac.", "スキャンはすべてこの Mac 上で行われます。", "L’analyse s’exécute entièrement sur ce Mac.", "Der Scan läuft vollständig auf diesem Mac."],
    "overview.diskUsageDetail": ["%@ free, %@ total", "剩余 %@，共 %@", "%@ 사용 가능, 총 %@", "%@ свободно, всего %@", "%@ libres, %@ en total", "空き %@，合計 %@", "%@ libres, %@ au total", "%@ frei, %@ gesamt"],
    "overview.lastCleanupTitle": ["Last cleanup released", "上次清理释放", "지난 정리로 확보", "Освобождено в прошлый раз", "Liberado en la última limpieza", "前回のクリーンアップで解放", "Libéré au dernier nettoyage", "Zuletzt freigegeben"],
    "overview.lastCleanupMeta": ["%@, %d items, moved to Trash", "%@，%d 项，全部移至废纸篓", "%@, %d개 항목, 휴지통으로 이동", "%@, элементов: %d, в Корзину", "%@, %d elementos, a la papelera", "%@，%d 項目，ゴミ箱へ移動", "%@, %d éléments, à la corbeille", "%@, %d Einträge, in den Papierkorb"],
    "overview.selectedSummary": ["%d selected, %@", "已选 %d 项，%@", "%d개 선택, %@", "Выбрано: %d, %@", "%d seleccionados, %@", "%d 件選択，%@", "%d sélectionnés, %@", "%d ausgewählt, %@"],
    "overview.moreItems": ["%d smaller items, %@ in total", "还有 %d 项较小内容，合计 %@", "작은 항목 %d개, 합계 %@", "Мелких элементов: %d, всего %@", "%d elementos menores, %@ en total", "小さい項目 %d 件，合計 %@", "%d éléments plus petits, %@ au total", "%d kleinere Einträge, %@ gesamt"],
    "overview.showAll": ["Show all", "展开全部", "모두 펼치기", "Показать все", "Mostrar todo", "すべて表示", "Tout afficher", "Alle anzeigen"],
    "overview.historyLocal": ["History stays on this Mac; nothing is synced or uploaded.", "记录仅保存在本机，不同步、不上传。", "기록은 이 Mac에만 저장되며 동기화되거나 업로드되지 않습니다.", "История хранится только на этом Mac и никуда не отправляется.", "El historial permanece en este Mac; no se sincroniza ni se sube.", "履歴はこの Mac にのみ保存され、同期や送信はされません。", "L’historique reste sur ce Mac ; rien n’est synchronisé ni envoyé.", "Der Verlauf bleibt auf diesem Mac; nichts wird synchronisiert oder hochgeladen."],
    "overview.activityScan": ["Scan finished, %d items", "扫描完成，%d 项", "검사 완료, %d개 항목", "Сканирование завершено, объектов: %d", "Análisis finalizado, %d elementos", "スキャン完了，%d 項目", "Analyse terminée, %d éléments", "Scan abgeschlossen, %d Objekte"],
    "overview.activityUninstall": ["Uninstall advice, %d apps not opened recently", "卸载建议，%d 个应用长期未打开", "제거 제안, 최근 미실행 앱 %d개", "Совет по удалению, приложений без запуска: %d", "Sugerencia de desinstalación, %d apps sin abrir", "アンインストール提案，長期間未使用 %d アプリ", "Conseil de désinstallation, %d apps inutilisées", "Deinstallationshinweis, %d Apps lange nicht geöffnet"],
    "overview.activityStorage": ["Storage analysed, %@ measured", "存储分析完成，已分析 %@", "저장 공간 분석 완료, %@ 분석", "Хранилище проанализировано, измерено %@", "Almacenamiento analizado, %@ medidos", "ストレージ分析完了，%@ を計測", "Stockage analysé, %@ mesurés", "Speicher analysiert, %@ gemessen"],

    "scan.filter.all": ["All", "全部", "전체", "Все", "Todo", "すべて", "Tout", "Alle"],
    "scan.filter.junk": ["Junk", "垃圾", "정리 대상", "Мусор", "Basura", "ジャンク", "Déchets", "Müll"],
    "scan.filter.large": ["Large", "大文件", "큰 파일", "Большие", "Grandes", "大きいファイル", "Volumineux", "Große"],
    "scan.filter.old": ["Old", "旧文件", "오래된 파일", "Старые", "Antiguos", "古いファイル", "Anciens", "Alte"],
    "scan.filter.duplicates": ["Duplicates", "重复", "중복", "Дубликаты", "Duplicados", "重複", "Doublons", "Duplikate"],
    "scan.rescan": ["Scan again", "重新扫描", "다시 검사", "Сканировать снова", "Analizar de nuevo", "再スキャン", "Relancer l’analyse", "Erneut scannen"],
    "scan.headerStatus": ["Results from %@ · %d items", "结果来自 %@ · 共 %d 项", "%@ 결과 · %d개 항목", "Результаты на %@ · объектов: %d", "Resultados de %@ · %d elementos", "%@ の結果 · %d 項目", "Résultats du %@ · %d éléments", "Ergebnisse vom %@ · %d Objekte"],
    "scan.results.safeGroup": ["Safe to clean", "可安全清理", "안전하게 정리 가능", "Можно безопасно очистить", "Se puede limpiar", "安全に削除可能", "Nettoyable sans risque", "Sicher bereinigbar"],
    "scan.results.reviewGroup": ["Needs your confirmation", "需要你确认", "확인 필요", "Требует подтверждения", "Requiere confirmación", "確認が必要", "À confirmer", "Bestätigung nötig"],
    "scan.results.protectedGroup": ["Protected", "受保护", "보호됨", "Защищено", "Protegido", "保護済み", "Protégé", "Geschützt"],
    "scan.results.defaultSelected": ["Selected by default", "默认已选中", "기본 선택됨", "Выбрано по умолчанию", "Seleccionado por defecto", "既定で選択", "Sélectionné par défaut", "Standardmäßig ausgewählt"],
    "scan.results.reviewHint": ["Confirm each item before cleaning", "逐项确认后才可清理", "항목별로 확인 후 정리할 수 있습니다", "Подтвердите каждый элемент", "Confirma cada elemento antes de limpiar", "項目ごとに確認してから削除します", "Confirmez chaque élément", "Jeden Eintrag bestätigen"],
    "scan.results.cleanTitle": ["This cleanup", "本次清理", "이번 정리", "Эта очистка", "Esta limpieza", "今回のクリーンアップ", "Ce nettoyage", "Diese Bereinigung"],
    "scan.results.cleanButton": ["Clean %d items", "清理 %d 项", "%d개 정리", "Очистить: %d", "Limpiar %d", "%d 件を削除", "Nettoyer %d", "%d bereinigen"],
    "scan.results.trashHint": ["Moves to the Trash; recoverable until you empty it.", "移入废纸篓，清空前可恢复。", "휴지통으로 이동하며, 비우기 전까지 복구할 수 있습니다.", "Перемещается в Корзину; можно восстановить до её очистки.", "Se mueve a la papelera; recuperable hasta vaciarla.", "ゴミ箱に移動し、空にするまで復元できます。", "Déplacé dans la corbeille ; récupérable jusqu’à ce que vous la vidiez.", "Wird in den Papierkorb verschoben; bis zum Leeren wiederherstellbar."],
    "scan.results.protectedHint": ["System files and protected locations are skipped automatically", "自动跳过系统文件与受保护路径", "시스템 파일과 보호된 경로는 자동으로 건너뜁니다", "Системные файлы и защищённые места пропускаются автоматически", "Los archivos del sistema y las ubicaciones protegidas se omiten", "システムファイルと保護された場所は自動で除外されます", "Les fichiers système et emplacements protégés sont ignorés", "Systemdateien und geschützte Orte werden automatisch übersprungen"],
    "scan.results.reportHint": ["Restore from the Trash, or export a cleanup report.", "可在废纸篓恢复，或导出清理报告。", "휴지통에서 복구하거나 정리 보고서를 내보낼 수 있습니다.", "Восстановите из Корзины или экспортируйте отчёт.", "Restaura desde la papelera o exporta un informe.", "ゴミ箱から復元するか、レポートを書き出せます。", "Restaurez depuis la corbeille ou exportez un rapport.", "Aus dem Papierkorb wiederherstellen oder einen Bericht exportieren."],
    "scan.results.sortSize": ["By size", "按大小", "크기순", "По размеру", "Por tamaño", "サイズ順", "Par taille", "Nach Größe"],
    "scan.results.sortName": ["By name", "按名称", "이름순", "По имени", "Por nombre", "名前順", "Par nom", "Nach Name"],
    "scan.results.sortModified": ["By modification date", "按修改时间", "수정일순", "По дате изменения", "Por fecha de modificación", "更新日順", "Par date de modification", "Nach Änderungsdatum"],
    "scan.results.categoryTotals": ["By category: %@", "按类别：%@", "카테고리별: %@", "По категориям: %@", "Por categoría: %@", "カテゴリ別: %@", "Par catégorie : %@", "Nach Kategorie: %@"],
    "scan.running.status": ["Scanning, step %d of %d", "扫描进行中，第 %d 步，共 %d 步", "검사 중, %d단계 / 총 %d단계", "Сканирование, шаг %d из %d", "Analizando, paso %d de %d", "スキャン中，%d / %d ステップ", "Analyse, étape %d sur %d", "Scan, Schritt %d von %d"],
    "scan.running.step": ["Step %d of %d", "第 %d 步，共 %d 步", "%d단계 / 총 %d단계", "Шаг %d из %d", "Paso %d de %d", "%d / %d ステップ", "Étape %d sur %d", "Schritt %d von %d"],
    "scan.running.target": ["Current target", "本轮目标", "현재 대상", "Текущая цель", "Objetivo actual", "現在の対象", "Cible actuelle", "Aktuelles Ziel"],
    "scan.running.walked": ["%@ files walked", "已遍历 %@ 个文件", "%@개 파일 탐색", "Просмотрено файлов: %@", "%@ archivos recorridos", "%@ ファイルを走査", "%@ fichiers parcourus", "%@ Dateien durchsucht"],
    "scan.running.found": ["%@ found", "已发现 %@", "%@ 발견", "Найдено %@", "%@ encontrados", "%@ を検出", "%@ trouvés", "%@ gefunden"],
    "scan.running.elapsed": ["Elapsed", "已用时", "경과 시간", "Прошло", "Tiempo transcurrido", "経過時間", "Temps écoulé", "Verstrichen"],
    "scan.running.phase": ["Current phase", "当前阶段", "현재 단계", "Текущий этап", "Fase actual", "現在のフェーズ", "Étape actuelle", "Aktuelle Phase"],
    "scan.running.readOnly": ["Reads names, sizes and modification dates only. It never opens files or uploads data.", "只读取文件名、大小与修改时间，不打开内容、不上传任何数据", "파일 이름, 크기, 수정일만 읽습니다. 내용을 열거나 데이터를 업로드하지 않습니다.", "Читаются только имена, размеры и даты изменения. Содержимое не открывается и никуда не отправляется.", "Solo lee nombres, tamaños y fechas de modificación. No abre archivos ni sube datos.", "名前・サイズ・更新日のみを読み取ります。中身を開いたり送信したりしません。", "Lit uniquement les noms, tailles et dates. N’ouvre jamais les fichiers et n’envoie rien.", "Liest nur Namen, Größen und Änderungsdaten. Öffnet keine Dateien und lädt nichts hoch."],
    "scan.running.categories": ["Found by category", "分类发现", "카테고리별 발견", "Найдено по категориям", "Encontrado por categoría", "カテゴリ別の検出", "Trouvé par catégorie", "Nach Kategorie gefunden"],
    "scan.running.categoryCount": ["%d categories", "%d 个类别", "%d개 카테고리", "Категорий: %d", "%d categorías", "%d カテゴリ", "%d catégories", "%d Kategorien"],
    "scan.running.waiting": ["Waiting", "等待中", "대기 중", "Ожидание", "En espera", "待機中", "En attente", "Wartet"],
    "scan.running.finding": ["Finding", "发现中", "발견 중", "Поиск", "Buscando", "検出中", "Recherche", "Sucht"],

    "apps.status": ["Installed %d, %d not opened in 6 months", "已安装 %d 个，%d 个超过 6 个月未打开", "설치 %d개, 6개월 이상 미실행 %d개", "Установлено: %d, не открывались 6 месяцев: %d", "%d instaladas, %d sin abrir en 6 meses", "インストール %d 件，6 か月以上未使用 %d 件", "%d installées, %d non ouvertes depuis 6 mois", "%d installiert, %d seit 6 Monaten nicht geöffnet"],
    "apps.listTitle": ["Applications", "应用列表", "앱 목록", "Приложения", "Aplicaciones", "アプリ一覧", "Applications", "Apps"],
    "apps.sortSummary": ["Sorted by size, %@ in total", "按体积排序，共 %@", "크기순, 총 %@", "По размеру, всего %@", "Por tamaño, %@ en total", "サイズ順，合計 %@", "Par taille, %@ au total", "Nach Größe, %@ gesamt"],
    "apps.reclaimable": ["Can be released", "本次可释放", "확보 가능", "Можно освободить", "Se puede liberar", "解放できる容量", "Libérable", "Freigebbar"],
    "apps.appAndRelated": ["App %@, related files %@", "应用本体 %@，关联文件 %@", "앱 %@, 관련 파일 %@", "Приложение %@, связанные файлы %@", "App %@, archivos relacionados %@", "アプリ %@，関連ファイル %@", "App %@, fichiers associés %@", "App %@, zugehörige Dateien %@"],
    "apps.relatedWillRemove": ["Related files to remove", "将一并删除的关联文件", "함께 삭제할 관련 파일", "Связанные файлы к удалению", "Archivos relacionados que se eliminarán", "一緒に削除する関連ファイル", "Fichiers associés à supprimer", "Zugehörige Dateien zum Entfernen"],
    "apps.uninstallAndClean": ["Uninstall and clean %@", "卸载并清理 %@", "제거하고 %@ 정리", "Удалить и очистить %@", "Desinstalar y limpiar %@", "アンインストールして %@ を整理", "Désinstaller et nettoyer %@", "Deinstallieren und %@ bereinigen"],
    "apps.restoreHint": ["Recoverable from the Trash until you empty it", "清空废纸篓前可恢复", "휴지통을 비우기 전까지 복구 가능", "Можно восстановить из Корзины до её очистки", "Recuperable de la papelera hasta vaciarla", "ゴミ箱を空にするまで復元できます", "Récupérable depuis la corbeille", "Bis zum Leeren des Papierkorbs wiederherstellbar"],
    "apps.footer": ["Showing apps over 200 MB, %d total", "仅显示超过 200 MB 的应用，共 %d 个", "200MB 초과 앱만 표시, 총 %d개", "Показаны приложения больше 200 МБ, всего %d", "Apps de más de 200 MB, %d en total", "200 MB 超のアプリのみ表示，全 %d 件", "Apps de plus de 200 Mo, %d au total", "Apps über 200 MB, %d gesamt"],
    "apps.lastOpened": ["Last opened %@", "上次打开于%@", "마지막 실행 %@", "Последний запуск: %@", "Última apertura: %@", "最終使用：%@", "Dernière ouverture : %@", "Zuletzt geöffnet: %@"],
    "apps.neverOpened": ["Never opened", "从未打开", "실행 기록 없음", "Не открывалось", "Nunca abierta", "未使用", "Jamais ouverte", "Nie geöffnet"],

    "storage.startTitle": ["See what occupies the disk", "看看磁盘被什么占用", "디스크를 무엇이 차지하는지 확인", "Посмотрите, что занимает диск", "Mira qué ocupa el disco", "ディスクを何が占めているか見る", "Voyez ce qui occupe le disque", "Sehen Sie, was den Speicher belegt"],
    "storage.status": ["%@, %@ used of %@", "%@，已用 %@，共 %@", "%@, %@ 사용 / 총 %@", "%@, занято %@ из %@", "%@, %@ usado de %@", "%@，%@ / %@ 使用", "%@, %@ utilisé sur %@", "%@, %@ von %@ belegt"],
    "storage.spaceDistribution": ["Space distribution", "空间分布", "공간 분포", "Распределение пространства", "Distribución del espacio", "スペースの内訳", "Répartition de l’espace", "Speicherverteilung"],
    "storage.categoryDetail": ["Category breakdown", "分类明细", "카테고리 내역", "По категориям", "Desglose por categoría", "カテゴリ別内訳", "Détail par catégorie", "Kategorieübersicht"],
    "storage.usageShare": ["Usage", "占用占比", "사용 비율", "Использовано", "Uso", "使用率", "Utilisation", "Belegung"],
    "storage.availableSpace": ["Available", "可用空间", "사용 가능", "Свободно", "Disponible", "空き容量", "Disponible", "Verfügbar"],
    "storage.localNote": ["Measured on this Mac. Nothing is uploaded or sent online.", "数据来自本机分析，不上传、不联网。", "이 Mac에서 분석한 데이터입니다. 업로드하거나 전송하지 않습니다.", "Измерено на этом Mac. Ничего не отправляется в сеть.", "Medido en este Mac. No se sube ni se envía nada.", "この Mac で計測したデータです。送信やアップロードは行いません。", "Mesuré sur ce Mac. Rien n’est envoyé en ligne.", "Auf diesem Mac gemessen. Nichts wird hochgeladen oder gesendet."],
    "storage.suggestionTitle": ["Suggestion", "建议", "제안", "Рекомендация", "Sugerencia", "提案", "Suggestion", "Empfehlung"],
    "storage.cleanableHeading": ["%@ can be cleaned", "%@ 可清理", "%@ 정리 가능", "Можно очистить %@", "Se pueden limpiar %@", "%@ を削除できます", "%@ peuvent être nettoyés", "%@ können bereinigt werden"],
    "storage.suggestionDetail": ["Start with caches and old installers, then scan again to confirm.", "先处理缓存和旧安装包，再扫描一次确认。", "캐시와 오래된 설치 파일부터 처리한 뒤 다시 검사하세요.", "Начните с кэшей и старых установщиков, затем просканируйте снова.", "Empieza por las cachés y los instaladores antiguos; luego analiza de nuevo.", "キャッシュと古いインストーラから処理し、もう一度スキャンしてください。", "Commencez par les caches et les anciens installateurs, puis relancez l’analyse.", "Beginnen Sie mit Caches und alten Installern und scannen Sie dann erneut."],
    "storage.goClean": ["Go clean", "去清理", "정리하러 가기", "Перейти к очистке", "Ir a limpiar", "整理する", "Nettoyer", "Bereinigen"],

    "settings.headerStatus": ["Settings, Sift %@", "设置，Sift %@", "설정, Sift %@", "Настройки, Sift %@", "Ajustes, Sift %@", "設定，Sift %@", "Réglages, Sift %@", "Einstellungen, Sift %@"],
    "language.search": ["Search languages", "搜索语言", "언어 검색", "Поиск языков", "Buscar idiomas", "言語を検索", "Rechercher une langue", "Sprachen suchen"],
    "language.noResults": ["No matching languages", "没有匹配的语言", "일치하는 언어가 없습니다", "Подходящих языков нет", "No hay idiomas coincidentes", "一致する言語がありません", "Aucune langue correspondante", "Keine passende Sprache"],

    # --- Trash and snapshots ---
    "trash.empty.action": ["Empty Trash", "清空废纸篓", "휴지통 비우기", "Очистить Корзину", "Vaciar la papelera", "ゴミ箱を空にする", "Vider la corbeille", "Papierkorb leeren"],
    "trash.empty.message": ["Permanently removes %@. This cannot be undone.", "将永久删除 %@，无法恢复。", "%@을(를) 영구적으로 삭제합니다. 되돌릴 수 없습니다.", "%@ будет удалено безвозвратно. Отменить это нельзя.", "Elimina %@ de forma permanente. No se puede deshacer.", "%@ を完全に削除します。元に戻せません。", "Supprime définitivement %@. Action irréversible.", "%@ wird endgültig gelöscht. Das lässt sich nicht rückgängig machen."],
    "diagnostics.snapshots.openTimeMachine": ["Open Time Machine", "打开时间机器", "Time Machine 열기", "Открыть Time Machine", "Abrir Time Machine", "Time Machine を開く", "Ouvrir Time Machine", "Time Machine öffnen"],

    # --- Coverage diagnostics ---
    "diagnostics.coverage.title": ["Rule coverage", "规则覆盖", "규칙 적용 범위", "Покрытие правил", "Cobertura de reglas", "ルールの適用範囲", "Couverture des règles", "Regelabdeckung"],
    "diagnostics.coverage.detail": ["Runs one scan with the current rule table, then reports what each rule found and which large folders no rule reaches at all.", "用当前规则表跑一次扫描，统计每条规则命中多少条目与体积，并列出一条规则都覆盖不到的大目录。", "현재 규칙 표로 한 번 검사하여 규칙별로 찾은 항목과 어느 규칙도 닿지 않는 큰 폴더를 보여 줍니다.", "Один проход по текущему набору правил: что нашло каждое правило и какие крупные папки не покрыты.", "Ejecuta un análisis con la tabla de reglas actual y muestra qué encontró cada regla y qué carpetas grandes no cubre ninguna.", "現在のルール表でスキャンを 1 回実行し、各ルールが見つけたものと、どのルールも届かない大きなフォルダーを示します。", "Lance une analyse avec la table de règles actuelle, puis indique ce que chaque règle a trouvé et les dossiers volumineux qu’aucune règle n’atteint.", "Führt einen Scan mit der aktuellen Regeltabelle aus und zeigt, was jede Regel findet und welche großen Ordner keine Regel erreicht."],
    "diagnostics.coverage.run": ["Run coverage audit", "运行覆盖诊断", "적용 범위 진단 실행", "Запустить аудит покрытия", "Ejecutar auditoría", "適用範囲を調べる", "Lancer l’audit", "Abdeckung prüfen"],
    "diagnostics.coverage.idle": ["Rules that found nothing: %@", "没有命中的规则：%@", "아무것도 찾지 못한 규칙: %@", "Правила без находок: %@", "Reglas sin resultados: %@", "何も見つからなかったルール: %@", "Règles sans résultat : %@", "Regeln ohne Treffer: %@"],
    "diagnostics.coverage.uncovered": ["Large folders no rule reaches", "没有规则覆盖的大目录", "어떤 규칙도 닿지 않는 큰 폴더", "Крупные папки без покрытия", "Carpetas grandes sin cobertura", "どのルールも届かない大きなフォルダー", "Dossiers volumineux non couverts", "Große Ordner ohne Regel"],
    "diagnostics.coverage.rule": ["Rule", "规则", "규칙", "Правило", "Regla", "ルール", "Règle", "Regel"],
    "diagnostics.coverage.synthesized": ["Scan", "内置扫描", "스캔", "Сканер", "Escaneo", "スキャン", "Analyse", "Scan"],
    "diagnostics.coverage.synthesizedNote": ["Rows marked “Scan” come from scanning code — residue, size and age thresholds — not from the rule file. No rule can express them, and a rule draft does not apply.", "标为「内置扫描」的行来自扫描代码（残留、体积与年龄阈值），不来自规则文件：规则无法表达它们，规则草稿对它们也不适用。", "「스캔」으로 표시된 행은 규칙 파일이 아니라 스캔 코드(잔여물, 크기·연령 임계값)에서 나옵니다. 규칙으로는 표현할 수 없고 규칙 초안도 해당되지 않습니다.", "Строки с пометкой «Сканер» приходят из кода сканирования — остатки, пороги размера и возраста, — а не из файла правил. Правилом их не выразить, и черновик правила к ним не применим.", "Las filas marcadas «Escaneo» provienen del código de escaneo —residuos, umbrales de tamaño y antigüedad—, no del archivo de reglas. Ninguna regla puede expresarlas y un borrador de regla no se aplica.", "「スキャン」と付いた行は、ルールファイルではなくスキャンのコード（残留物、サイズ・経過日数のしきい値）から出たものです。ルールでは表現できず、ルールの下書きも適用されません。", "Les lignes marquées « Analyse » viennent du code d’analyse — résidus, seuils de taille et d’ancienneté —, pas du fichier de règles. Aucune règle ne peut les exprimer et un brouillon de règle ne s’y applique pas.", "Mit „Scan“ markierte Zeilen stammen aus dem Scan-Code — Rückstände, Größen- und Altersschwellen —, nicht aus der Regeldatei. Keine Regel kann sie ausdrücken, und ein Regelentwurf gilt dafür nicht."],

    # --- Rule drafts ---
    "diagnostics.coverage.draftTitle": ["Rule draft", "规则草稿", "규칙 초안", "Черновик правила", "Borrador de regla", "ルールの下書き", "Brouillon de règle", "Regelentwurf"],
    "diagnostics.coverage.draftDetail": ["Add this to your own rule file, then turn on “Use a custom rule file” in Settings. Nothing is cleaned until you do.", "把这段加入你自己的规则文件，然后在设置中开启「使用自定义规则文件」。在此之前不会清理任何东西。", "이 내용을 사용자 규칙 파일에 추가한 뒤 설정에서 ‘사용자 규칙 파일 사용’을 켜세요. 그 전에는 아무것도 정리되지 않습니다.", "Добавьте это в свой файл правил и включите «Использовать собственный файл правил» в настройках. До этого ничего не удаляется.", "Añade esto a tu propio archivo de reglas y activa «Usar un archivo de reglas propio» en Ajustes. Hasta entonces no se limpia nada.", "この内容を自分のルールファイルに追加し、設定で「カスタムルールファイルを使用」をオンにしてください。それまでは何も削除されません。", "Ajoutez ceci à votre propre fichier de règles, puis activez « Utiliser un fichier de règles personnalisé » dans Réglages. Rien n’est supprimé avant cela.", "Fügen Sie dies Ihrer eigenen Regeldatei hinzu und aktivieren Sie in den Einstellungen „Eigene Regeldatei verwenden“. Vorher wird nichts gelöscht."],
    "diagnostics.coverage.draftCopy": ["Copy", "复制", "복사", "Копировать", "Copiar", "コピー", "Copier", "Kopieren"],
    "diagnostics.coverage.draftCannot": ["This folder cannot be covered by a rule: %@", "这个目录不能由规则覆盖：%@", "이 폴더는 규칙으로 다룰 수 없습니다: %@", "Эту папку нельзя описать правилом: %@", "Esta carpeta no puede cubrirse con una regla: %@", "このフォルダーはルールで扱えません: %@", "Ce dossier ne peut pas être couvert par une règle : %@", "Dieser Ordner lässt sich nicht durch eine Regel abdecken: %@"],

    # --- Residue categories ---
    "cleanup.category.groupContainerResidue": ["Shared container residue", "共享容器残留", "공유 컨테이너 잔여물", "Остатки общих контейнеров", "Residuos de contenedores compartidos", "共有コンテナの残留", "Résidus de conteneurs partagés", "Reste gemeinsamer Container"],

    # --- Residue ownership ---
    "uninstall.sharedContainer": ["Also shared with: %@", "也被这些应用共用：%@", "다음 앱과도 공유됩니다: %@", "Также используется: %@", "También compartido con: %@", "次のアプリとも共有されています: %@", "Aussi partagé avec : %@", "Auch geteilt mit: %@"],
    "scan.results.ownerAction": ["Which app is this?", "查看所属应用", "어느 앱인가요?", "Какое это приложение?", "¿De qué app es?", "どのアプリのもの？", "De quelle app ?", "Von welcher App?"],
    "scan.results.ownerMissing": ["No application is installed for %@. The identifier has been copied.", "该应用未安装（%@），标识符已复制。", "%@에 해당하는 앱이 설치되어 있지 않습니다. 식별자를 복사했습니다.", "Приложение для %@ не установлено. Идентификатор скопирован.", "No hay ninguna aplicación instalada para %@. Se ha copiado el identificador.", "%@ に該当するアプリはインストールされていません。識別子をコピーしました。", "Aucune application installée pour %@. L’identifiant a été copié.", "Für %@ ist keine App installiert. Die Kennung wurde kopiert."],

    # --- Cleanup confirmation ----------------------------------------------------
    "cleanup.confirm.titleCount": [
        "Move %d items to Trash?",
        "把这 %d 个项目移入废纸篓？",
        "%d개 항목을 휴지통으로 이동할까요?",
        "Переместить %d объектов в Корзину?",
        "¿Mover %d elementos a la papelera?",
        "%d 項目をゴミ箱に移動しますか？",
        "Déplacer %d éléments vers la corbeille ?",
        "%d Objekte in den Papierkorb verschieben?",
    ],
    "cleanup.confirm.moveAction": ["Move to Trash", "移入废纸篓", "휴지통으로 이동", "В Корзину", "Mover a la papelera", "ゴミ箱に入れる", "Mettre à la corbeille", "In den Papierkorb"],
    "cleanup.confirm.showItems": [
        "Review each item (%d)",
        "逐项查看（%d 项）",
        "항목별로 확인 (%d개)",
        "Проверить каждый (%d)",
        "Revisar cada elemento (%d)",
        "項目ごとに確認（%d 件）",
        "Vérifier chaque élément (%d)",
        "Einzeln prüfen (%d)",
    ],
    "cleanup.confirm.hideItems": ["Hide the list", "收起清单", "목록 접기", "Скрыть список", "Ocultar la lista", "リストを閉じる", "Masquer la liste", "Liste ausblenden"],
    "cleanup.confirm.locations": ["Locations", "将移动的位置", "이동할 위치", "Расположения", "Ubicaciones", "移動先", "Emplacements", "Speicherorte"],
    "cleanup.confirm.protectedCount": [
        "%d protected, not moved",
        "%d 项受保护，不会移动",
        "%d개는 보호되어 이동하지 않음",
        "%d защищено, не перемещено",
        "%d protegidos, sin mover",
        "%d 件は保護され、移動しません",
        "%d protégés, non déplacés",
        "%d geschützt, nicht verschoben",
    ],
    "cleanup.confirm.missingCount": [
        "%d already gone, skipped",
        "%d 项已不存在，自动跳过",
        "%d개는 이미 없어 건너뜀",
        "%d уже нет, пропущено",
        "%d ya no existen, omitidos",
        "%d 件は既になく、スキップ",
        "%d déjà absents, ignorés",
        "%d nicht mehr vorhanden, übersprungen",
    ],
    "cleanup.confirm.reviewCount": ["%d need your review", "%d 项需要你确认", "%d개 확인 필요", "%d требуют проверки", "%d requieren tu revisión", "%d 件の確認が必要です", "%d à vérifier", "%d zu prüfen"],
    "cleanup.confirm.whyRecoverable": [
        "Why this is recoverable",
        "为什么可以恢复",
        "복구할 수 있는 이유",
        "Почему это можно восстановить",
        "Por qué se puede recuperar",
        "復元できる理由",
        "Pourquoi c’est récupérable",
        "Warum das wiederherstellbar ist",
    ],

    # --- Cleanup progress and result ---------------------------------------------
    "cleanup.preparing.title": ["Checking items", "正在检查项目", "항목 확인 중", "Проверка объектов", "Comprobando elementos", "項目を確認しています", "Vérification des éléments", "Objekte werden geprüft"],
    "cleanup.executing.title": [
        "Moving to Trash",
        "正在移入废纸篓",
        "휴지통으로 이동 중",
        "Перемещение в Корзину",
        "Moviendo a la papelera",
        "ゴミ箱に移動しています",
        "Déplacement vers la corbeille",
        "Wird in den Papierkorb verschoben",
    ],
    "cleanup.executing.progress": ["%d of %d", "已移 %d / 共 %d", "%d / %d", "%d из %d", "%d de %d", "%d / %d", "%d sur %d", "%d von %d"],
    "cleanup.result.reclaimAfterEmpty": [
        "Available space grows by %@ once you empty the Trash",
        "清空废纸篓后，可用空间增加 %@",
        "휴지통을 비우면 사용 가능한 공간이 %@ 늘어납니다",
        "После очистки Корзины свободного места станет больше на %@",
        "El espacio disponible crecerá %@ al vaciar la papelera",
        "ゴミ箱を空にすると空き容量が %@ 増えます",
        "L’espace disponible augmentera de %@ quand vous viderez la corbeille",
        "Der freie Speicher wächst um %@, sobald Sie den Papierkorb leeren",
    ],
    "cleanup.result.retryCount": ["Retry %d", "重试这 %d 项", "%d개 다시 시도", "Повторить %d", "Reintentar %d", "%d 件を再試行", "Réessayer %d", "%d erneut versuchen"],
    "cleanup.result.undoAction": [
        "Undo this cleanup",
        "撤销这次清理",
        "이번 정리 되돌리기",
        "Отменить очистку",
        "Deshacer esta limpieza",
        "この整理を元に戻す",
        "Annuler ce nettoyage",
        "Bereinigung rückgängig machen",
    ],
    "cleanup.result.undoUnavailable": [
        "Can't undo: the Trash was emptied or the item is on another disk",
        "无法撤销：废纸篓已清空，或项目位于另一个磁盘",
        "되돌릴 수 없음: 휴지통이 비었거나 항목이 다른 디스크에 있습니다",
        "Отмена невозможна: Корзина очищена или объект на другом диске",
        "No se puede deshacer: la papelera se vació o el elemento está en otro disco",
        "元に戻せません：ゴミ箱が空にされたか、項目が別のディスクにあります",
        "Annulation impossible : la corbeille a été vidée ou l’élément est sur un autre disque",
        "Nicht rückgängig zu machen: Der Papierkorb wurde geleert oder das Objekt liegt auf einer anderen Festplatte",
    ],
    "cleanup.result.stopped": [
        "Stopped after %d items",
        "已停止，共移入 %d 项",
        "%d개 항목에서 중지됨",
        "Остановлено после %d объектов",
        "Detenido tras %d elementos",
        "%d 件で停止しました",
        "Arrêté après %d éléments",
        "Nach %d Objekten gestoppt",
    ],

    # --- Scan state --------------------------------------------------------------
    "scan.stopped.title": ["Scan stopped", "扫描已停止", "검사 중지됨", "Сканирование остановлено", "Análisis detenido", "スキャンを停止しました", "Analyse arrêtée", "Scan gestoppt"],
    "scan.stopped.detail": [
        "%d items (%@) were found before you stopped. You can still clean them.",
        "停止前已找到 %d 项（%@），仍可清理。",
        "중지하기 전에 %d개 항목(%@)을 찾았습니다. 계속 정리할 수 있습니다.",
        "До остановки найдено %d объектов (%@). Их всё ещё можно очистить.",
        "Se encontraron %d elementos (%@) antes de detener. Aún puedes limpiarlos.",
        "停止する前に %d 件（%@）が見つかりました。引き続き整理できます。",
        "%d éléments (%@) ont été trouvés avant l’arrêt. Vous pouvez encore les nettoyer.",
        "Vor dem Stopp wurden %d Objekte (%@) gefunden. Sie können sie weiterhin bereinigen.",
    ],
    "scan.stopping": ["Stopping…", "正在停止…", "중지 중…", "Остановка…", "Deteniendo…", "停止しています…", "Arrêt…", "Wird gestoppt…"],
    "scan.hiddenSelected": [
        "%d selected items are not shown here",
        "有 %d 项已选中但未显示在此列表",
        "선택한 %d개 항목은 이 목록에 표시되지 않습니다",
        "Выбранные объекты (%d) здесь не показаны",
        "%d elementos seleccionados no se muestran aquí",
        "選択した %d 件はこの一覧に表示されていません",
        "%d éléments sélectionnés ne sont pas affichés ici",
        "%d ausgewählte Objekte werden hier nicht angezeigt",
    ],
    "scan.nothingFoundScope": [
        "Nothing in this scope",
        "当前范围没有可清理项",
        "이 범위에 정리할 항목이 없습니다",
        "В этой области ничего нет",
        "Nada en este ámbito",
        "この範囲には何もありません",
        "Rien dans ce périmètre",
        "In diesem Bereich nichts gefunden",
    ],

    # --- File cleanup empty states -----------------------------------------------
    "files.noDuplicatesDetail": [
        "No duplicate files in the folders Sift scanned.",
        "在已扫描的文件夹里没有发现重复文件。",
        "Sift가 검사한 폴더에 중복 파일이 없습니다.",
        "В папках, которые просканировал Sift, дубликатов нет.",
        "No hay archivos duplicados en las carpetas analizadas por Sift.",
        "Sift がスキャンしたフォルダーに重複ファイルはありません。",
        "Aucun fichier en double dans les dossiers analysés par Sift.",
        "In den von Sift gescannten Ordnern gibt es keine Duplikate.",
    ],

    # --- Full Disk Access and scan scope -----------------------------------------
    "permission.askTitle": [
        "Let Sift read a little more?",
        "让 Sift 看得更全一些？",
        "Sift가 조금 더 읽도록 허용할까요?",
        "Разрешить Sift читать немного больше?",
        "¿Permitir que Sift lea un poco más?",
        "Sift にもう少し読み取りを許可しますか？",
        "Autoriser Sift à lire un peu plus ?",
        "Sift etwas mehr lesen lassen?",
    ],
    "permission.whyTitle": [
        "Why Full Disk Access",
        "为什么需要完全磁盘访问权限",
        "전체 디스크 접근 권한이 필요한 이유",
        "Зачем нужен полный доступ к диску",
        "Por qué el acceso total al disco",
        "フルディスクアクセスが必要な理由",
        "Pourquoi l’accès complet au disque",
        "Warum vollständiger Festplattenzugriff",
    ],
    "permission.whyBody": [
        "It covers system logs and app support folders, which macOS protects. Everything else works without it.",
        "它能读取系统日志与应用支持目录，这些位置受 macOS 保护。其他功能无需该权限。",
        "시스템 로그와 앱 지원 폴더는 macOS가 보호하고 있어 이 권한이 있어야 읽을 수 있습니다. 나머지 기능은 없어도 동작합니다.",
        "Он открывает системные журналы и папки поддержки приложений, которые защищает macOS. Всё остальное работает и без него.",
        "Cubre los registros del sistema y las carpetas de soporte de apps, que macOS protege. Todo lo demás funciona sin él.",
        "システムログとアプリのサポートフォルダーは macOS が保護しているため、この権限があれば読み取れます。ほかの機能は権限なしでも動作します。",
        "Il couvre les journaux système et les dossiers de support des apps, que macOS protège. Tout le reste fonctionne sans.",
        "Er umfasst Systemprotokolle und App-Support-Ordner, die macOS schützt. Alles andere funktioniert auch ohne.",
    ],
    "permission.whyRevoke": [
        "You can switch it off in System Settings → Privacy & Security at any time.",
        "可随时在系统设置 → 隐私与安全性中关闭。",
        "언제든 시스템 설정 → 개인정보 보호 및 보안에서 끌 수 있습니다.",
        "Отключить можно в любой момент: Системные настройки → Конфиденциальность и безопасность.",
        "Puedes desactivarlo cuando quieras en Ajustes del Sistema → Privacidad y seguridad.",
        "システム設定 → プライバシーとセキュリティでいつでもオフにできます。",
        "Vous pouvez le désactiver à tout moment dans Réglages → Confidentialité et sécurité.",
        "Sie können ihn jederzeit unter Systemeinstellungen → Datenschutz & Sicherheit abschalten.",
    ],
    "permission.openedSettings": [
        "System Settings is open. Come back and scan again.",
        "已打开系统设置，授权后回来重新扫描。",
        "시스템 설정을 열었습니다. 권한을 준 뒤 돌아와 다시 검사하세요.",
        "Системные настройки открыты. Вернитесь и запустите сканирование снова.",
        "Ajustes del Sistema está abierto. Vuelve y analiza de nuevo.",
        "システム設定を開きました。戻ってきて再度スキャンしてください。",
        "Réglages est ouvert. Revenez et relancez l’analyse.",
        "Die Systemeinstellungen sind offen. Kommen Sie zurück und scannen Sie erneut.",
    ],
    "permission.protectedTitle": ["Protected by Sift", "Sift 保护的路径", "Sift가 보호하는 경로", "Защищено Sift", "Protegido por Sift", "Sift が保護するパス", "Protégé par Sift", "Von Sift geschützt"],
    "permission.systemProtectedTitle": ["Locations macOS keeps closed", "系统保护的位置", "macOS가 보호하는 위치", "Папки, закрытые в macOS", "Ubicaciones cerradas por macOS", "macOS が保護している場所", "Emplacements fermés par macOS", "Von macOS geschützte Orte"],
    "permission.restartHint": ["If Full Disk Access is already on, quit Sift and open it again — macOS applies the grant when an app starts.", "如果已经打开完全磁盘访问权限，请退出 Sift 后重新打开；macOS 只在应用启动时应用该授权。", "전체 디스크 접근 권한이 이미 켜져 있다면 Sift를 종료한 뒤 다시 여십시오. macOS는 앱이 시작될 때 권한을 적용합니다.", "Если «Полный доступ к диску» уже включён, закройте Sift и откройте его снова: macOS применяет разрешение при запуске приложения.", "Si el acceso al disco completo ya está activado, cierra Sift y vuelve a abrirlo: macOS aplica el permiso al iniciar la app.", "フルディスクアクセスがすでにオンなら、Sift を終了してから開き直してください。macOS はアプリの起動時に権限を適用します。", "Si l'accès complet au disque est déjà activé, quittez Sift puis rouvrez-le : macOS applique l'autorisation au démarrage de l'app.", "Wenn „Vollständiger Festplattenzugriff“ bereits aktiv ist, beende Sift und öffne es erneut – macOS wendet die Freigabe beim Start einer App an."],
    "scan.skippedReason.systemRestricted": ["macOS or another user owns this location, so Sift cannot read it.", "这个位置属于 macOS 或其他用户，Sift 无法读取。", "이 위치는 macOS 또는 다른 사용자 소유여서 Sift가 읽을 수 없습니다.", "Эта папка принадлежит macOS или другому пользователю, поэтому Sift не может её прочитать.", "Esta ubicación pertenece a macOS o a otro usuario, así que Sift no puede leerla.", "この場所は macOS または別のユーザーが所有しているため、Sift は読み取れません。", "Cet emplacement appartient à macOS ou à un autre utilisateur, Sift ne peut donc pas le lire.", "Dieser Ort gehört macOS oder einem anderen Benutzer, daher kann Sift ihn nicht lesen."],
    "scan.firstRun.scope": [
        "Sift reads caches, logs and installers in these locations:",
        "Sift 会读取这些位置的缓存、日志与安装包：",
        "Sift는 다음 위치의 캐시, 로그, 설치 파일을 읽습니다:",
        "Sift читает кэши, журналы и установщики в этих местах:",
        "Sift lee cachés, registros e instaladores en estas ubicaciones:",
        "Sift は次の場所のキャッシュ、ログ、インストーラを読み取ります：",
        "Sift lit les caches, journaux et installateurs de ces emplacements :",
        "Sift liest Caches, Protokolle und Installer an diesen Orten:",
    ],
    "scan.scopeNote": [
        "Reads names, sizes and dates only · full coverage needs Full Disk Access",
        "只读取文件名、大小与时间 · 完整覆盖需完全磁盘访问",
        "이름, 크기, 날짜만 읽습니다 · 전체 범위는 전체 디스크 접근 권한이 필요합니다",
        "Читаются только имена, размеры и даты · для полного охвата нужен полный доступ к диску",
        "Solo lee nombres, tamaños y fechas · la cobertura total requiere acceso total al disco",
        "読み取るのは名前・サイズ・日付のみ · 全範囲にはフルディスクアクセスが必要です",
        "Lit uniquement les noms, tailles et dates · la couverture complète demande l’accès complet au disque",
        "Liest nur Namen, Größen und Daten · volle Abdeckung braucht vollständigen Festplattenzugriff",
    ],

    # --- Purchase, settings and navigation ---------------------------------------
    "purchase.activate": [
        "Activate a licence key",
        "激活授权码",
        "라이선스 키 활성화",
        "Активировать лицензионный ключ",
        "Activar una clave de licencia",
        "ライセンスキーを有効化",
        "Activer une clé de licence",
        "Lizenzschlüssel aktivieren",
    ],
    "purchase.openStore": ["Buy on the website", "去官网购买", "웹사이트에서 구매", "Купить на сайте", "Comprar en el sitio web", "ウェブサイトで購入", "Acheter sur le site", "Auf der Website kaufen"],
    "purchase.unavailable": [
        "In-app purchase is not available in this build.",
        "这个版本暂不支持应用内购买。",
        "이 빌드에서는 앱 내 구매를 사용할 수 없습니다.",
        "В этой сборке покупка в приложении недоступна.",
        "La compra dentro de la app no está disponible en esta versión.",
        "このビルドではアプリ内購入を利用できません。",
        "L’achat intégré n’est pas disponible dans cette version.",
        "In-App-Kauf ist in diesem Build nicht verfügbar.",
    ],
    "settings.showConfirmList": [
        "Show the item list before cleaning",
        "清理前显示清单",
        "정리 전에 항목 목록 표시",
        "Показывать список перед очисткой",
        "Mostrar la lista antes de limpiar",
        "整理前に項目一覧を表示",
        "Afficher la liste avant de nettoyer",
        "Liste vor dem Bereinigen anzeigen",
    ],
    "settings.showConfirmListWarning": [
        "Turning this off removes the last checkpoint. Items still go to the Trash, but you will not see what moves.",
        "关闭后就没有最后一道核对。项目仍会进入废纸篓，但你看不到将移动什么。",
        "끄면 마지막 확인 단계가 사라집니다. 항목은 휴지통으로 이동하지만 무엇이 이동하는지 보지 못합니다.",
        "Если выключить, последняя проверка исчезнет. Объекты всё равно попадут в Корзину, но вы не увидите, что именно.",
        "Si lo desactivas, desaparece la última comprobación. Los elementos van a la papelera, pero no verás qué se mueve.",
        "オフにすると最後の確認がなくなります。項目はゴミ箱に移動しますが、何が移動するかは表示されません。",
        "Si vous désactivez, le dernier contrôle disparaît. Les éléments vont dans la corbeille, mais vous ne verrez pas ce qui part.",
        "Wenn Sie das abschalten, entfällt die letzte Kontrolle. Objekte gehen weiterhin in den Papierkorb, Sie sehen aber nicht, was verschoben wird.",
    ],
    "settings.includeHidden": [
        "Include hidden files in scans",
        "扫描包含隐藏文件",
        "검사에 숨김 파일 포함",
        "Включать скрытые файлы в сканирование",
        "Incluir archivos ocultos en los análisis",
        "スキャンに隠しファイルを含める",
        "Inclure les fichiers cachés dans les analyses",
        "Versteckte Dateien in Scans einbeziehen",
    ],
    "trash.emptyConfirmAction": ["Delete permanently", "永久删除", "영구 삭제", "Удалить безвозвратно", "Eliminar permanentemente", "完全に削除", "Supprimer définitivement", "Endgültig löschen"],
    "common.copyReason": ["Copy reason", "复制原因", "이유 복사", "Скопировать причину", "Copiar motivo", "理由をコピー", "Copier la raison", "Grund kopieren"],
    "common.stop": ["Stop", "停止", "중지", "Остановить", "Detener", "停止", "Arrêter", "Stoppen"],
    "cleanup.busyNotice": ["Another operation is still running. Try again in a moment.", "另一个操作还在进行，请稍后再试。", "다른 작업이 아직 진행 중입니다. 잠시 후 다시 시도하세요.", "Другая операция ещё выполняется. Повторите чуть позже.", "Hay otra operación en curso. Inténtalo de nuevo en un momento.", "別の操作がまだ実行中です。しばらくしてからもう一度お試しください。", "Une autre opération est en cours. Réessayez dans un instant.", "Ein anderer Vorgang läuft noch. Versuchen Sie es gleich noch einmal."],
    "cleanup.nothingToDo": ["Nothing in this selection can be moved right now.", "当前选中的内容暂时无法移动。", "지금은 선택한 항목을 옮길 수 없습니다.", "Сейчас ничего из выбранного переместить нельзя.", "Ahora mismo no se puede mover nada de lo seleccionado.", "現在、選択した項目は移動できません。", "Rien de la sélection ne peut être déplacé pour l'instant.", "Aus dieser Auswahl lässt sich gerade nichts bewegen."],
    "scan.partialBudget": ["Scan stopped early to stay responsive — the results are partial.", "扫描为保持流畅提前结束，结果不完整。", "응답성을 위해 스캔을 일찍 마쳤습니다. 결과가 일부만 포함됩니다.", "Сканирование завершилось раньше, чтобы интерфейс оставался отзывчивым. Результаты неполные.", "El análisis terminó antes para no bloquear la app: los resultados son parciales.", "応答性を保つためスキャンを早めに終了しました。結果は一部のみです。", "L'analyse s'est arrêtée plus tôt pour rester fluide : les résultats sont partiels.", "Der Scan wurde früher beendet, damit die App bedienbar bleibt — die Ergebnisse sind unvollständig."],
    "settings.ignoreEmpty": ["No folder is ignored yet.", "还没有忽略任何文件夹。", "아직 제외한 폴더가 없습니다.", "Пока нет исключённых папок.", "Aún no hay carpetas excluidas.", "除外したフォルダはまだありません。", "Aucun dossier exclu pour l'instant.", "Noch kein Ordner ausgenommen."],
    "settings.addFolder": ["Add a folder", "添加文件夹", "폴더 추가", "Добавить папку", "Añadir carpeta", "フォルダを追加", "Ajouter un dossier", "Ordner hinzufügen"],
    "settings.keepHistory": ["Scan history to keep", "保留的扫描记录条数", "보관할 스캔 기록 수", "Сколько сканирований хранить", "Análisis a conservar", "保存するスキャン履歴", "Analyses à conserver", "Aufzubewahrende Scans"],
    "settings.launchAtLogin": ["Open Sift at login", "登录时打开 Sift", "로그인 시 Sift 열기", "Открывать Sift при входе", "Abrir Sift al iniciar sesión", "ログイン時に Sift を開く", "Ouvrir Sift à l'ouverture de session", "Sift bei der Anmeldung öffnen"],
    "common.today": ["Today", "今天", "오늘", "Сегодня", "Hoy", "今日", "Aujourd’hui", "Heute"],
    "common.yesterday": ["Yesterday", "昨天", "어제", "Вчера", "Ayer", "昨日", "Hier", "Gestern"],
    "common.daysAgo": ["%d days ago", "%d 天前", "%d일 전", "%d дней назад", "Hace %d días", "%d 日前", "Il y a %d jours", "Vor %d Tagen"],
    "settings.textSize": ["Text size", "界面字号", "글자 크기", "Размер текста", "Tamaño del texto", "文字サイズ", "Taille du texte", "Textgröße"],
    "settings.textSizeSmall": ["Small", "小", "작게", "Мелкий", "Pequeño", "小", "Petit", "Klein"],
    "settings.textSizeDefault": ["Default", "默认", "기본", "Обычный", "Predeterminado", "標準", "Par défaut", "Standard"],
    "settings.textSizeLarge": ["Large", "大", "크게", "Крупный", "Grande", "大", "Grand", "Groß"],
    "scan.firstRun.review": ["First cleanup: expand the list before you confirm.", "第一次清理：确认前建议展开清单看一眼。", "첫 정리입니다. 확인 전에 목록을 펼쳐 보세요.", "Первая очистка: раскройте список перед подтверждением.", "Primera limpieza: despliega la lista antes de confirmar.", "初めてのクリーンアップです。確認前に一覧を開いてください。", "Premier nettoyage : ouvrez la liste avant de confirmer.", "Erste Bereinigung: Klappen Sie die Liste vor dem Bestätigen auf."],
}

# Languages added with the 2.0 expansion. They are appended to every row in
# this order, after the v1 columns above.
EXPANSION_LANGUAGES = ["it", "pt-br", "zh-hant", "tr", "pl", "nl"]

# key: [it, pt-BR, zh-Hant, tr, pl, nl]
#
# The expansion table must cover exactly the same keys as STRINGS; the merge
# below fails the generation when the two drift apart, so a key added to one
# table cannot ship without its translations.
STRINGS_EXPANSION: dict[str, list[str]] = {
    # --- Application shell -------------------------------------------------
    "nav.dashboard": ["Panoramica", "Visão geral", "總覽", "Genel Bakış", "Przegląd", "Overzicht"],
    "nav.smartScan": ["Scansione intelligente", "Verificação inteligente", "智慧掃描", "Akıllı Tarama", "Inteligentne skanowanie", "Slimme scan"],
    "nav.junkCleanup": ["Pulizia file inutili", "Limpeza de arquivos inúteis", "垃圾清理", "Gereksiz Temizliği", "Czyszczenie śmieci", "Rommel opschonen"],
    "nav.uninstaller": ["Disinstallazione", "Desinstalador", "軟體解除安裝", "Uygulama Kaldırma", "Deinstalacja", "Verwijderprogramma"],
    "nav.fileCleanup": ["Pulizia dei file", "Limpeza de arquivos", "檔案清理", "Dosya Temizliği", "Czyszczenie plików", "Bestanden opschonen"],
    "nav.storageAnalysis": ["Archiviazione", "Armazenamento", "儲存空間", "Depolama", "Pamięć masowa", "Opslag"],
    "nav.settings": ["Impostazioni", "Ajustes", "設定", "Ayarlar", "Ustawienia", "Instellingen"],
    "nav.privacy": ["Privacy", "Privacidade", "隱私權", "Gizlilik", "Prywatność", "Privacy"],

    # --- Dashboard ---------------------------------------------------------
    "dashboard.scanCard.title": ["Trova ciò che puoi pulire in sicurezza", "Descubra o que pode ser limpo com segurança", "找出可以安全清理的內容", "Güvenle temizlenecek şeyleri bulun", "Znajdź to, co można bezpiecznie wyczyścić", "Vind wat veilig opgeruimd kan worden"],
    "dashboard.scanCard.subtitle": ["Cache, log, programmi di installazione e file residui. Ogni elemento mostra origine e scopo prima della rimozione.", "Caches, logs, instaladores e arquivos residuais. Cada item mostra a origem e a finalidade antes da remoção.", "掃描快取、記錄檔、安裝程式和殘留檔案。所有項目都會在刪除前顯示來源和用途。", "Önbellekler, günlükler, yükleyiciler ve artık dosyalar. Her öğe silinmeden önce kaynağını ve amacını gösterir.", "Pamięci podręczne, dzienniki, instalatory i pozostałości plików. Każdy element pokazuje źródło i cel przed usunięciem.", "Caches, logbestanden, installatieprogramma’s en achtergebleven bestanden. Elk item toont bron en doel vóór verwijdering."],
    "dashboard.startScan": ["Avvia la scansione", "Iniciar verificação", "開始掃描", "Taramayı Başlat", "Rozpocznij skanowanie", "Scan starten"],
    "dashboard.lastScan": ["Ultima scansione: %@", "Última verificação: %@", "上次掃描：%@", "Son tarama: %@", "Ostatnie skanowanie: %@", "Laatste scan: %@"],
    "dashboard.neverScanned": ["Non ancora scansionato", "Ainda não verificado", "尚未掃描", "Henüz taranmadı", "Jeszcze nie skanowano", "Nog niet gescand"],
    "dashboard.diskUsed": ["Spazio utilizzato", "Disco usado", "磁碟已使用", "Disk kullanımı", "Zajętość dysku", "Schijfgebruik"],
    "dashboard.diskFree": ["%@ disponibili", "%@ livres", "%@ 可用", "%@ boş", "%@ wolne", "%@ vrij"],
    "dashboard.suggestedCleanup": ["Suggeriti per primi", "Sugeridos primeiro", "建議優先處理", "Önce bunlar", "Najpierw do zrobienia", "Eerst voorgesteld"],
    "dashboard.recentActivity": ["Attività recente", "Atividade recente", "最近活動", "Son etkinlikler", "Ostatnia aktywność", "Recente activiteit"],
    "dashboard.cleanupCompleted": ["Pulizia completata", "Limpeza concluída", "清理完成", "Temizlik tamamlandı", "Czyszczenie ukończone", "Opruiming voltooid"],
    "dashboard.scanCompleted": ["Scansione completata", "Verificação concluída", "掃描完成", "Tarama tamamlandı", "Skanowanie ukończone", "Scan voltooid"],
    "dashboard.now": ["Adesso", "Agora", "現在", "Şimdi", "Teraz", "Nu"],
    "dashboard.lookSuggestions": ["Vedi i suggerimenti", "Ver sugestões", "查看建議", "Önerileri gör", "Zobacz sugestie", "Bekijk suggesties"],
    # __MORE_KEYS__

    # --- Scan --------------------------------------------------------------
    "scan.phase.idle": ["In attesa di scansionare", "Aguardando verificação", "等待掃描", "Tarama bekleniyor", "Oczekiwanie na skanowanie", "Wacht op de scan"],
    "scan.phase.preparing": ["Preparazione di cartelle e permessi", "Preparando pastas e permissões", "準備目錄和權限", "Klasörler ve izinler hazırlanıyor", "Przygotowywanie folderów i uprawnień", "Mappen en machtigingen worden voorbereid"],
    "scan.phase.scanning": ["Scansione in corso", "Verificando", "掃描中", "Taranıyor", "Skanowanie w toku", "Scannen"],
    "scan.phase.indexing": ["Calcolo delle dimensioni e raggruppamento dei duplicati", "Medindo tamanhos e agrupando duplicados", "計算大小並分組重複檔案", "Boyutlar hesaplanıyor, kopyalar gruplanıyor", "Obliczanie rozmiarów i grupowanie duplikatów", "Grootten berekenen en duplicaten groeperen"],
    "scan.phase.ready": ["Scansione completata", "Verificação concluída", "掃描完成", "Tarama tamamlandı", "Skanowanie ukończone", "Scan voltooid"],
    "scan.phase.cancelled": ["Scansione annullata", "Verificação cancelada", "掃描已取消", "Tarama iptal edildi", "Skanowanie anulowane", "Scan geannuleerd"],
    "scan.phase.partial": ["Alcune posizioni non si sono lasciate leggere", "Alguns locais não puderam ser lidos", "部分位置無法存取", "Bazı konumlar okunamadı", "Niektórych lokalizacji nie udało się odczytać", "Sommige locaties konden niet worden gelezen"],
    "scan.phase.failed": ["Scansione non riuscita", "Falha na verificação", "掃描失敗", "Tarama başarısız oldu", "Skanowanie nie powiodło się", "Scan mislukt"],
    "scan.currentItem": ["Verifica in corso: %@", "Verificando: %@", "正在檢查：%@", "Kontrol ediliyor: %@", "Sprawdzanie: %@", "Bezig met controleren: %@"],
    "scan.cancel": ["Annulla la scansione", "Cancelar verificação", "取消掃描", "Taramayı iptal et", "Anuluj skanowanie", "Scan annuleren"],
    "scan.results": ["Risultati", "Resultados", "掃描結果", "Sonuçlar", "Wyniki", "Resultaten"],
    "scan.selectAll": ["Seleziona tutto", "Selecionar tudo", "全選", "Tümünü seç", "Zaznacz wszystko", "Selecteer alles"],
    "scan.deselectAll": ["Deseleziona tutto", "Desmarcar tudo", "取消全選", "Seçimin kaldır", "Odznacz wszystko", "Deselecteer alles"],
    "scan.selectAllShown": ["Seleziona i visibili (%d)", "Selecionar os exibidos (%d)", "全選已顯示（%d 項）", "Görünenlerin tümünü seç (%d)", "Zaznacz wszystkie widoczne (%d)", "Alles wat getoond wordt selecteren (%d)"],
    "scan.nothingFound": ["Niente da pulire", "Nada para limpar", "沒有可清理項目", "Temizlenecek bir şey yok", "Nic do wyczyszczenia", "Niets op te ruimen"],
    "scan.nothingFoundDetail": ["Sift non ha trovato cache, log, installer o residui da rimuovere.", "O Sift não encontrou caches, logs, instaladores ou restos que valham a pena remover.", "Sift 沒有發現值得移除的快取、記錄檔、安裝程式或殘留項目。", "Sift kaldırmaya değer önbellek, günlük, yükleyici veya artık bulamadı.", "Sift nie znalazł pamięci podręcznych, dzienników, instalatorów ani pozostałości wartych usunięcia.", "Sift vond geen caches, logbestanden, installatieprogramma’s of resten die verwijdering waard zijn."],
    "scan.partialNotice": ["%d posizioni ignorate", "%d locais ignorados", "%d 個位置已被略過", "%d konum atlandı", "Pominięto %d lokalizacji", "%d locaties overgeslagen"],
    "scan.openSystemSettings": ["Apri Impostazioni di Sistema", "Abrir Ajustes do Sistema", "打開系統設定", "Sistem Ayarları’nı aç", "Otwórz Ustawienia systemowe", "Open Systeeminstellingen"],
    "scan.skippedReason.permissionDenied": ["Sift richiede un permesso aggiuntivo per questa posizione.", "Esta localização precisa de permissão adicional.", "這個位置需要額外權限。", "Bu konum için ek izin gerekiyor.", "Ta lokalizacja wymaga dodatkowych uprawnień.", "Voor deze locatie is een extra machtiging nodig."],
    "scan.skippedReason.protectedLocation": ["Sift non tocca mai questa posizione, per proteggere i tuoi file.", "O Sift nunca mexe nesta localização, para proteger seus arquivos.", "為保護你的檔案，Sift 不會處理此位置。", "Dosyalarınızı korumak için Sift bu konuma hiç dokunmaz.", "Sift nigdy nie dotyka tej lokalizacji, aby chronić Twoje pliki.", "Sift raakt deze locatie nooit aan, om je bestanden te beschermen."],
    "scan.skippedReason.fileNotFound": ["L’elemento è scomparso durante la scansione ed è stato ignorato.", "O item desapareceu durante a verificação e foi ignorado.", "項目在掃描過程中被移除，已略過。", "Öğe tarama sırasında kayboldu ve atlandı.", "Element zniknął podczas skanowania i został pominięty.", "Het item verdween tijdens de scan en is overgeslagen."],
    "scan.skippedReason.partialFailure": ["Una parte di questa posizione non è leggibile.", "Parte desta localização não pôde ser lida.", "此位置的一部分無法讀取。", "Bu konumun bir kısmı okunamadı.", "Części tej lokalizacji nie udało się odczytać.", "Een deel van deze locatie kon niet worden gelezen."],
    "scan.skippedReason.timedOut": ["Questa cartella non ha risposto, quindi è stata ignorata.", "Esta pasta não respondeu, então foi ignorada.", "此目錄長時間無回應，已跳過。", "Bu klasör yanıt vermedi, bu yüzden atlandı.", "Ten folder nie odpowiedział, więc został pominięty.", "Deze map reageerde niet en is daarom overgeslagen."],
    # --- Cleanup -----------------------------------------------------------
    "cleanup.category.applicationCache": ["Cache delle app", "Caches de apps", "應用程式快取", "Uygulama önbellekleri", "Pamięci podręczne aplikacji", "App-caches"],
    "cleanup.category.logs": ["Log", "Logs", "記錄檔", "Günlükler", "Dzienniki", "Logbestanden"],
    "cleanup.category.installers": ["Vecchi installer", "Instaladores antigos", "舊安裝程式", "Eski yükleyiciler", "Stare instalatory", "Oude installatieprogramma’s"],
    "cleanup.category.temporaryFiles": ["File temporanei", "Arquivos temporários", "暫存檔案", "Geçici dosyalar", "Pliki tymczasowe", "Tijdelijke bestanden"],
    "cleanup.category.largeFiles": ["File grandi", "Arquivos grandes", "大型檔案", "Büyük dosyalar", "Duże pliki", "Grote bestanden"],
    "cleanup.category.oldFiles": ["File datati", "Arquivos antigos", "舊檔案", "Eski dosyalar", "Stare pliki", "Oude bestanden"],
    "cleanup.category.duplicateFiles": ["File duplicati", "Arquivos duplicados", "重複檔案", "Kopya dosyalar", "Duplikaty plików", "Dubbele bestanden"],
    "cleanup.category.applicationResidue": ["Residui di app", "Restos de apps", "應用程式殘留", "Uygulama artıkları", "Pozostałości aplikacji", "App-restanten"],
    "cleanup.category.developerArtifacts": ["Artefatti di build", "Artefatos de build", "開發建置產物", "Derleme çıktıları", "Artefakty kompilacji", "Build-artefacten"],


    "cleanup.explanation.cache": ["Le app ricreano questi file alla successiva esecuzione.", "Os apps recriam esses arquivos na próxima execução.", "應用程式下次執行時會重新產生這些檔案。", "Uygulamalar bu dosyaları bir sonraki çalıştırmada yeniden oluşturur.", "Aplikacje odtworzą te pliki przy następnym uruchomieniu.", "De apps maken deze bestanden opnieuw aan bij de volgende keer dat ze draaien."],
    "cleanup.explanation.logs": ["File di log più vecchi di %d giorni. Non influiscono sul funzionamento delle app.", "Arquivos de log com mais de %d dias. Não afetam o funcionamento dos apps.", "%d 天前的記錄檔案。不影響應用程式正常執行。", "%d günden eski günlük dosyaları. Uygulamaların çalışmasını etkilemez.", "Pliki dzienników starsze niż %d dni. Nie wpływają na działanie aplikacji.", "Logbestanden ouder dan %d dagen. Ze beïnvloeden de apps niet."],
    "cleanup.explanation.logsItem": ["File di log datati. Rimuoverli non cambia il funzionamento delle app.", "Arquivos de log antigos. Removê-los não afeta o funcionamento dos apps.", "過期記錄檔案。刪除它們不會影響應用程式執行。", "Eski günlük dosyaları. Bunları kaldırmak uygulamaların çalışmasını değiştirmez.", "Przestarzałe pliki dzienników. Ich usunięcie nie zmienia działania aplikacji.", "Verouderde logbestanden. Ze verwijderen verandert niets aan de werking van de apps."],
    "cleanup.explanation.systemLogsItem": ["File di log di sistema datati. Alcuni richiedono l’Accesso completo al disco per essere letti.", "Arquivos de log do sistema antigos. Alguns exigem o Acesso Total ao Disco para serem lidos.", "過期的系統記錄檔案。讀取其中一部分需要「完全磁碟存取權限」。", "Eski sistem günlük dosyaları. Bazılarını okumak Tam Disk Erişimi gerektirir.", "Przestarzałe dzienniki systemowe. Odczyt niektórych wymaga pełnego dostępu do dysku.", "Verouderde systeemlogbestanden. Sommige lezen vereist Volledige Schijftoegang."],
    "cleanup.explanation.installers": ["Installer già utilizzati. Potresti averne ancora bisogno: conferma prima.", "Instaladores que você já usou. Ainda pode precisar deles; confirme antes.", "已經使用過的安裝程式。你可能仍需要它們，請先確認。", "Zaten kullandığınız yükleyiciler. Hâlâ gerekebilir; önce onaylayın.", "Instalatory, które zostały już użyte. Mogą jeszcze być potrzebne — najpierw potwierdź.", "Installatieprogramma’s die je al hebt gebruikt. Je kunt ze nog nodig hebben — bevestig eerst."],
    "cleanup.explanation.temporary": ["File di lavoro lasciati dalle app.", "Arquivos temporários deixados pelos apps.", "應用程式留下的暫存檔案。", "Uygulamaların geride bıraktığı geçici dosyalar.", "Pliki robocze pozostawione przez aplikacje.", "Tijdelijke werkbestanden die de apps achterlieten."],
    "cleanup.explanation.xcodeArchives": ["Build archiviate. Il progetto può essere archiviato di nuovo, ma questa archiviazione non è recuperabile.", "Compilações arquivadas. O projeto pode ser arquivado de novo, mas este arquivo não pode ser recuperado.", "封存的建置產物。專案可以重新封存，但這份封存無法復原。", "Arşivlenmiş derlemeler. Proje yeniden arşivlenebilir, ancak bu arşiv geri getirilemez.", "Zarchiwizowane kompilacje. Projekt można zarchiwizować ponownie, ale tego archiwum nie da się odzyskać.", "Gearchiveerde builds. Het project kan opnieuw worden gearchiveerd, maar dit archief is niet te herstellen."],
    "cleanup.explanation.buildArtifacts": ["Output di una compilazione. La prossima build lo ricrea.", "Saída de uma compilação. A próxima build cria de novo.", "編譯器寫出的建置產物，重新編譯就會再次產生。", "Bir derlemenin çıktısı. Sonraki derleme yeniden oluşturur.", "Wynik kompilacji. Kolejne kompilowanie utworzy go ponownie.", "Uitvoer van een build. De volgende build maakt het opnieuw aan."],

    "cleanup.explanation.simulatorDevices": ["Dispositivi del simulatore e tutto ciò che vi è installato. Il dispositivo si può ricreare; le app che contiene vanno reinstallate.", "Dispositivos do simulador e tudo o que está instalado neles. O dispositivo pode ser criado de novo; os apps dentro dele precisam ser instalados outra vez.", "模擬器裝置及其內部安裝的內容。裝置可以重新建立，裡面的應用程式需要重新安裝。", "Simülatör aygıtları ve içlerine kurulan her şey. Aygıt yeniden oluşturulabilir; içindeki uygulamalar yeniden kurulmalıdır.", "Urządzenia symulatora i wszystko, co w nich zainstalowano. Urządzenie można utworzyć od nowa; aplikacje w nim trzeba zainstalować ponownie.", "Simulatorapparaten en alles wat erin is geïnstalleerd. Het apparaat kan opnieuw worden aangemaakt; de apps erin moeten opnieuw worden geïnstalleerd."],
    "cleanup.explanation.largeFiles": ["File più grandi di %@. Sift non indovina: sei tu a decidere cosa rimuovere.", "Arquivos maiores que %@. O Sift não adivinha: você decide o que remover.", "大於 %@ 的檔案。Sift 不做猜測，由你決定刪除哪些。", "%@ üzeri dosyalar. Sift tahmin yapmaz: neyin kaldırılacağına siz karar verirsiniz.", "Pliki większe niż %@. Sift nie zgaduje: to Ty decydujesz, co usunąć.", "Bestanden groter dan %@. Sift gokt niet: jij bepaalt wat er verwijderd wordt."],
    "cleanup.explanation.largeFilesItem": ["Un file di grandi dimensioni. Sift non indovina: sei tu a decidere cosa rimuovere.", "Um arquivo grande. O Sift não adivinha: você decide o que remover.", "大型檔案。Sift 不做猜測，由你決定刪除哪些。", "Büyük bir dosya. Sift tahmin yapmaz: neyin kaldırılacağına siz karar verirsiniz.", "Duży plik. Sift nie zgaduje: to Ty decydujesz, co usunąć.", "Een groot bestand. Sift gokt niet: jij bepaalt wat er verwijderd wordt."],
    "cleanup.explanation.oldFiles": ["Non modificati da %d giorni e più grandi di 10 MB.", "Sem alteração há %d dias e maiores que 10 MB.", "%d 天未修改且大於 10 MB。", "%d gündür değişmemiş ve 10 MB’tan büyük.", "Niezmieniane od %d dni i większe niż 10 MB.", "Al %d dagen niet gewijzigd en groter dan 10 MB."],
    "cleanup.explanation.oldFilesItem": ["A lungo senza modifiche e più grande di 10 MB.", "Sem alteração há muito tempo e maior que 10 MB.", "長期未修改且大於 10 MB。", "Uzun süredir değişmemiş ve 10 MB’tan büyük.", "Dawno niezmieniany i większy niż 10 MB.", "Al lang niet gewijzigd en groter dan 10 MB."],
    "cleanup.explanation.duplicates": ["Contenuto identico. Conserva una copia e rimuovi le altre.", "Conteúdo idêntico. Mantenha uma cópia e remova as demais.", "內容完全相同。保留一份，刪除其餘。", "İçerik birebir aynı. Bir kopyayı tutun, gerisini kaldırın.", "Identyczna zawartość. Zachowaj jedną kopię i usuń pozostałe.", "Identieke inhoud. Bewaar één exemplaar en verwijder de rest."],
    "cleanup.explanation.residue": ["Residui di un’app non più installata.", "Restos de um app que não está mais instalado.", "來自已解除安裝應用程式的殘留檔案。", "Artık yüklü olmayan bir uygulamadan kalanlar.", "Pozostałości po aplikacji, która nie jest już zainstalowana.", "Achtergebleven van een app die niet meer geïnstalleerd is."],
    "cleanup.explanation.residuePreferences": ["File di preferenze senza un’app installata corrispondente.", "Arquivo de preferências sem um app instalado correspondente.", "沒有對應已安裝應用程式的偏好設定檔案。", "Kurulu karşılığı olmayan bir tercihler dosyası.", "Plik preferencji bez pasującej zainstalowanej aplikacji.", "Voorkeurenbestand zonder een bijbehorende geïnstalleerde app."],
    "cleanup.explanation.residueWebStorage": ["Dati web di un’app non più installata.", "Armazenamento web de um app que não está mais instalado.", "已解除安裝應用程式的網頁儲存資料。", "Artık yüklü olmayan bir uygulamanın web depolama verisi.", "Dane sieciowe aplikacji, która nie jest już zainstalowana.", "Webopslag van een app die niet meer geïnstalleerd is."],
    "cleanup.explanation.residueGroupContainer": ["Contenitore condiviso di un’app non più installata.", "Contêiner compartilhado de um app que não está mais instalado.", "已解除安裝應用程式的共享容器。", "Artık yüklü olmayan bir uygulamanın paylaşılan kapsayıcısı.", "Wspólny kontener aplikacji, która nie jest już zainstalowana.", "Gedeelde container van een app die niet meer geïnstalleerd is."],
    "cleanup.explanation.savedState": ["Stato delle finestre salvato per app che non sono più in esecuzione.", "Estado de janelas salvo de apps que já não estão em execução.", "為已結束的應用程式儲存的視窗狀態。", "Çalışmayan uygulamalar için kaydedilmiş pencere durumu.", "Stan okien zapisany dla aplikacji, które już nie działają.", "Vensterstatus opgeslagen voor apps die niet meer draaien."],

    "risk.safe.short": ["Sicuro", "Seguro", "安全", "Güvenli", "Bezpieczne", "Veilig"],
    "risk.review.short": ["Da verificare", "Revisar", "需確認", "Kontrol et", "Do sprawdzenia", "Controleren"],
    "risk.protected.short": ["Protetto", "Protegido", "受保護", "Korumalı", "Chronione", "Beschermd"],
    "risk.safe.detail": ["Ricreato automaticamente se necessario. Selezionato per impostazione predefinita.", "Recriado automaticamente se necessário. Selecionado por padrão.", "需要時會自動重建。預設已選取。", "Gerekirse otomatik olarak yeniden oluşturulur. Varsayılan olarak seçilidir.", "W razie potrzeby odtwarzane automatycznie. Domyślnie zaznaczone.", "Wordt indien nodig automatisch opnieuw aangemaakt. Standaard geselecteerd."],
    "risk.review.detail": ["Di solito si può rimuovere, ma è meglio confermare.", "Normalmente pode ser removido, mas é melhor confirmar.", "通常可以刪除，但建議你確認。", "Genellikle kaldırılabilir, ancak onaylamanız iyi olur.", "Zwykle można usunąć, ale lepiej potwierdzić.", "Meestal veilig te verwijderen, maar bevestig het beter."],
    "risk.protected.detail": ["Sift non lo rimuoverà. Mostrato solo come informazione.", "O Sift não remove isto. Exibido apenas como informação.", "Sift 不會刪除此內容，僅作說明。", "Sift bunu kaldırmaz. Yalnızca bilgi amaçlı gösterilir.", "Sift tego nie usunie. Pokazane wyłącznie informacyjnie.", "Sift verwijdert dit niet. Alleen ter informatie getoond."],

    "cleanup.confirm.title": ["Spostare nel Cestino?", "Mover para a Lixeira?", "移入垃圾桶？", "Çöp Sepeti’ne taşınsın mu?", "Przenieść do Kosza?", "Naar de Prullenbak verplaatsen?"],
    "cleanup.confirm.moveCount": ["Sposta %d elementi nel Cestino, %@ in totale", "Mover %d itens para a Lixeira, %@ no total", "將 %d 個項目移入垃圾桶，共 %@", "%d öğeyi Çöp Sepeti’ne taşı, toplam %@", "Przenieś %d elementów do Kosza, łącznie %@", "%d items naar de Prullenbak verplaatsen, totaal %@"],
    "cleanup.confirm.moveCountOne": ["Sposta 1 elemento nel Cestino, %@ in totale", "Mover 1 item para a Lixeira, %@ no total", "將 1 個項目移入垃圾桶，共 %@", "1 öğeyi Çöp Sepeti’ne taşı, toplam %@", "Przenieś 1 element do Kosza, łącznie %@", "1 item naar de Prullenbak verplaatsen, totaal %@"],
    "cleanup.confirm.undoNotice": ["Tutto finisce nel Cestino: puoi ripristinarlo finché non lo svuoti.", "Tudo vai para a Lixeira, então você pode recuperar até esvaziá-la.", "所有內容都會進入垃圾桶，在清空前都可以還原。", "Her şey Çöp Sepeti’ne gider; boşaltana kadar geri alabilirsiniz.", "Wszystko trafia do Kosza, więc możesz przywrócić do jego opróżnienia.", "Alles gaat naar de Prullenbak, dus je kunt het terugzetten totdat je die leegt."],
    "cleanup.confirm.selectedItems": ["%d selezionati", "%d selecionados", "已選 %d 項", "%d seçildi", "Wybrano: %d", "%d geselecteerd"],
    "cleanup.confirm.methodValue": ["Sposta nel Cestino (recuperabile)", "Mover para a Lixeira (recuperável)", "移入垃圾桶（可還原）", "Çöp Sepeti’ne taşı (geri alınabilir)", "Przenieś do Kosza (do przywrócenia)", "Naar de Prullenbak (terug te zetten)"],
    "cleanup.confirm.cancel": ["Annulla", "Cancelar", "取消", "İptal", "Anuluj", "Annuleer"],
    "cleanup.confirm.skipConfirmation": ["Non chiedere la prossima volta", "Pular confirmação da próxima vez", "下次略過確認", "Bir dahaki sefere onayı atla", "Nie pytaj następnym razem", "Volgende keer niet vragen"],
    "cleanup.confirm.riskWarning": ["Hai incluso elementi da verificare. Controlla l’elenco prima di continuare.", "Você incluiu itens marcados para revisão. Verifique a lista antes de continuar.", "你已選取標記為需確認的項目。繼續前請檢查列表。", "Kontrol edilmesi işaretli öğeler eklediniz. Devam etmeden önce listeyi gözden geçirin.", "Uwzględniłeś elementy oznaczone do sprawdzenia. Przed kontynuacją sprawdź listę.", "Je hebt items opgenomen die om controle vragen. Controleer de lijst voordat je doorgaat."],

    "cleanup.result.title": ["Pulizia completata", "Limpeza concluída", "清理完成", "Temizlik tamamlandı", "Czyszczenie zakończone", "Opruimen voltooid"],
    "cleanup.result.moved": ["%d elementi spostati nel Cestino", "%d itens movidos para a Lixeira", "%d 個項目已移入垃圾桶", "%d öğe Çöp Sepeti’ne taşındı", "%d elementów przeniesiono do Kosza", "%d items naar de Prullenbak verplaatst"],
    "cleanup.result.released": ["Liberati %@", "%@ liberados", "釋放 %@", "%@ kazanıldı", "Odzyskano %@", "%@ vrijgemaakt"],
    "cleanup.result.showTrash": ["Mostra il Cestino nel Finder", "Mostrar a Lixeira no Finder", "在 Finder 中查看垃圾桶", "Çöp Sepeti’ni Finder’da göster", "Pokaż Kosz w Finderze", "Toon de Prullenbak in de Finder"],
    "cleanup.result.undoHint": ["Ripristina gli elementi dal Cestino finché non lo svuoti.", "Recupere os itens da Lixeira até esvaziá-la.", "在清空垃圾桶之前，你可以隨時還原這些項目。", "Çöp Sepeti’ni boşaltana kadar öğeleri geri alabilirsiniz.", "Przywróć elementy z Kosza, dopóki go nie opróżnisz.", "Zet items terug uit de Prullenbak totdat je die leegt."],
    "cleanup.result.details": ["Dettagli degli elementi", "Detalhes dos itens", "項目明細", "Öğe ayrıntıları", "Szczegóły elementów", "Itemdetails"],
    "cleanup.result.exportReport": ["Esporta il rapporto in PDF", "Exportar relatório em PDF", "將報告輸出為 PDF", "Raporu PDF olarak dışa aktar", "Wyeksportuj raport jako PDF", "Rapport als PDF exporteren"],

    "cleanup.failure.permissionDenied": ["Serve accesso al disco", "Precisa de acesso ao disco", "需要磁碟存取權限", "Disk erişimi gerekiyor", "Wymaga dostępu do dysku", "Vereist schijftoegang"],
    "cleanup.failure.fileNotFound": ["Già rimosso", "Já removido", "已被移除", "Zaten kaldırılmış", "Już usunięto", "Al verwijderd"],
    "cleanup.failure.fileInUse": ["In uso, saltato", "Em uso, ignorado", "使用中，略過", "Kullanımda, atlandı", "W użyciu, pominięto", "In gebruik, overgeslagen"],
    "cleanup.failure.itemChanged": ["Modificato, saltato", "Alterado, ignorado", "已變更，略過", "Değişti, atlandı", "Zmieniono, pominięto", "Gewijzigd, overgeslagen"],
    "cleanup.failure.volumeUnavailable": ["Disco scollegato", "Disco desconectado", "磁碟已斷開", "Disk bağlı değil", "Dysk odłączony", "Schijf losgekoppeld"],
    "cleanup.failure.protectedLocation": ["Posizione protetta", "Localização protegida", "受保護的位置", "Korumalı konum", "Lokalizacja chroniona", "Beschermd locatie"],
    "cleanup.failure.partialFailure": ["Fatto in parte", "Feito em parte", "部分完成", "Kısmen yapıldı", "Zrobione częściowo", "Deels gedaan"],
    # --- Uninstaller -------------------------------------------------------
    "uninstall.search": ["Cerca app", "Buscar apps", "搜尋應用程式", "Uygulama ara", "Szukaj aplikacji", "Apps zoeken"],
    "uninstall.sort.name": ["Nome", "Nome", "名稱", "Ad", "Nazwa", "Naam"],
    "uninstall.sort.size": ["Dimensione", "Tamanho", "佔用空間", "Boyut", "Rozmiar", "Grootte"],
    "uninstall.sort.lastUsed": ["Ultimo utilizzo", "Último uso", "最近使用", "Son kullanım", "Ostatnio używane", "Laatst gebruikt"],
    "uninstall.noneInstalled": ["Nessuna app di terze parti trovata", "Nenhum app de terceiros encontrado", "沒有找到第三方應用程式", "Üçüncü taraf uygulama bulunamadı", "Nie znaleziono aplikacji innych producentów", "Geen apps van derden gevonden"],
    "uninstall.systemApp": ["Non disinstallabile", "Não pode ser desinstalado", "不可解除安裝", "Kaldırılamaz", "Nie można odinstalować", "Kan niet worden verwijderd"],
    "uninstall.systemAppDetail": ["Sift rimuove solo le app che hai installato tu.", "O Sift só remove apps que você mesmo instalou.", "Sift 只處理你自己安裝的應用程式。", "Sift yalnızca sizin yüklediğiniz uygulamaları kaldırır.", "Sift usuwa tylko aplikacje, które samodzielnie zainstalowałeś.", "Sift verwijdert alleen apps die je zelf hebt geïnstalleerd."],
    "uninstall.needsReview": ["Richiedono la tua conferma", "Precisam da sua confirmação", "需要手動確認", "Onayınızı gerektiriyor", "Wymagają Twojego potwierdzenia", "Vragen om jouw bevestiging"],
    "uninstall.reason.bundleIdentifier": ["Il nome è l’identificatore bundle di questa app.", "O nome é o identificador de bundle deste app.", "名稱就是該應用程式的 bundle identifier。", "Ad, bu uygulamanın bundle tanımlayıcısıdır.", "Nazwa to identyfikator bundle tej aplikacji.", "De naam is de bundle-identificatie van deze app."],
    "uninstall.reason.identifierPrefix": ["Il nome inizia con l’identificatore bundle di questa app.", "O nome começa com o identificador de bundle deste app.", "名稱以該應用程式的 bundle identifier 開頭。", "Ad, bu uygulamanın bundle tanımlayıcısıyla başlıyor.", "Nazwa zaczyna się od identyfikatora bundle tej aplikacji.", "De naam begint met de bundle-identificatie van deze app."],
    "uninstall.reason.applicationName": ["Il nome coincide con quello dell’app, in una cartella che macOS riserva a ciascuna app.", "O nome coincide exatamente com o do app, em uma pasta que o macOS mantém por app.", "名稱與應用程式名稱完全一致，且位於 macOS 按應用程式存放資料的目錄。", "Ad, uygulamanın adıyla birebir aynı ve macOS’un uygulama başına kullandığı klasörde.", "Nazwa dokładnie odpowiada aplikacji, w folderze, który macOS prowadzi per aplikacja.", "De naam komt exact overeen met de app, in een map die macOS per app bijhoudt."],
    "uninstall.reason.identifierSuffix": ["Il nome corrisponde all’ultima parte dell’identificatore bundle di questa app.", "O nome corresponde à última parte do identificador de bundle deste app.", "名稱與該應用程式 bundle identifier 的最後一段一致。", "Ad, bu uygulamanın bundle tanımlayıcısının son bölümüyle eşleşiyor.", "Nazwa odpowiada ostatniej części identyfikatora bundle tej aplikacji.", "De naam komt overeen met het laatste deel van de bundle-identificatie van deze app."],
    "uninstall.reason.appGroup": ["Il contenitore appartiene a un gruppo di app dichiarato da questa app.", "O contêiner pertence a um grupo de apps declarado por este app.", "此容器屬於本應用程式所宣告的應用程式群組。", "Konteyner, bu uygulamanın bildirdiği bir uygulama grubuna ait.", "Kontener należy do grupy aplikacji zadeklarowanej przez tę aplikację.", "De container hoort bij een app-groep die deze app opgeeft."],
    "uninstall.copyGroupIdentifier": ["Copia identificatore del gruppo", "Copiar identificador do grupo", "拷貝群組識別碼", "Grup tanımlayıcısını kopyala", "Kopiuj identyfikator grupy", "Groepsidentificatie kopiëren"],
    "uninstall.appRunning": ["%@ è in esecuzione. Chiudila prima di rimuoverla, altrimenti Sift salterà i file che tiene aperti.", "%@ está em execução. Encerre-o antes de remover, ou o Sift ignorará os arquivos em uso.", "%@ 正在執行。請先結束，否則 Sift 會略過被佔用的檔案。", "%@ çalışıyor. Kaldırmadan önce kapatın, yoksa Sift kullanımdaki dosyaları atlar.", "%@ jest uruchomiona. Zamknij ją przed usunięciem, w przeciwnym razie Sift pominie używane pliki.", "%@ draait. Sluit het eerst af, anders slaat Sift de open bestanden over."],
    "uninstall.quitFailed": ["Sift non è riuscito a chiedere a %@ di chiudersi. Chiudila manualmente e riprova.", "O Sift não conseguiu pedir para %@ encerrar. Feche manualmente e tente de novo.", "Sift 無法要求 %@ 結束。請手動結束後重試。", "Sift, %@’yı kapanması için uyaramadı. Elle kapatıp yeniden deneyin.", "Sift nie mógł poprosić %@ o zamknięcie. Zamknij ją ręcznie i spróbuj ponownie.", "Sift kon %@ niet vragen af te sluiten. Sluit het handmatig af en probeer het opnieuw."],
    "uninstall.noRelatedFiles": ["Nessun file correlato trovato.", "Nenhum arquivo relacionado foi encontrado.", "沒有找到相關檔案。", "İlgili dosya bulunamadı.", "Nie znaleziono plików powiązanych.", "Er zijn geen gerelateerde bestanden gevonden."],
    "uninstall.selectApp": ["Scegli un’app per vedere cosa verrebbe rimosso.", "Escolha um app para ver o que seria removido.", "選擇一個應用程式以查看將被刪除的內容。", "Neyin kaldırılacağını görmek için bir uygulama seçin.", "Wybierz aplikację, aby zobaczyć, co zostałoby usunięte.", "Kies een app om te zien wat er verwijderd zou worden."],

    # --- File cleanup ------------------------------------------------------
    "files.mode.large": ["File grandi", "Arquivos grandes", "大型檔案", "Büyük dosyalar", "Duże pliki", "Grote bestanden"],
    "files.mode.old": ["File datati", "Arquivos antigos", "舊檔案", "Eski dosyalar", "Stare pliki", "Oude bestanden"],
    "files.mode.duplicates": ["Duplicati", "Duplicados", "重複檔案", "Kopyalar", "Duplikaty", "Duplicaten"],
    "files.duplicateGroups": ["%d gruppi di duplicati, %@ recuperabile", "%d grupos de duplicados, %@ recuperável", "%d 個重複群組，可釋放 %@", "%d kopya grubu, %@ kazanılabilir", "%d grup duplikatów, %@ do odzyskania", "%d duplicaatgroepen, %@ vrij te maken"],
    "files.duplicateGroupsShown": ["Gruppi mostrati: %d di %d", "Mostrando %d de %d grupos", "已顯示 %d / %d 群組", "%d / %d grup gösteriliyor", "Wyświetlono %d z %d grup", "%d van %d groepen getoond"],
    "files.groupMembers": ["%d copie", "%d cópias", "%d 份副本", "%d kopya", "%d kopii", "%d exemplaren"],
    "files.keepThis": ["Conserva questo", "Manter este", "保留此項", "Bunu tut", "Zachowaj ten", "Deze bewaren"],
    "files.noDuplicates": ["Nessun file duplicato trovato", "Nenhum arquivo duplicado encontrado", "沒有找到重複檔案", "Kopya dosya bulunamadı", "Nie znaleziono duplikatów", "Geen dubbele bestanden gevonden"],
    "files.revealInFinder": ["Mostra nel Finder", "Mostrar no Finder", "在 Finder 中顯示", "Finder’da göster", "Pokaż w Finderze", "Toon in de Finder"],
    "files.requiresAuthorization": ["Sift scansiona Download, Scrivania e le cartelle che scegli. Aggiungi una cartella per includerla.", "O Sift verifica Downloads, Área de Trabalho e as pastas que você escolher. Adicione uma pasta para incluí-la.", "Sift 只掃描「下載」、「桌面」和你選擇的資料夾。加入資料夾以納入掃描。", "Sift, İndirilenler, Masaüstü ve seçtiğiniz klasörleri tarar. Dahil etmek için klasör ekleyin.", "Sift skanuje Pobrane, Biurko i wybrane foldery. Dodaj folder, aby go uwzględnić.", "Sift scant Downloads, Bureaublad en de mappen die je kiest. Voeg een map toe om die op te nemen."],
    "files.addFolder": ["Aggiungi cartella", "Adicionar pasta", "加入資料夾", "Klasör ekle", "Dodaj folder", "Map toevoegen"],

    # --- System diagnostics ------------------------------------------------
    "diagnostics.category.spotlightIndex": ["Indice Spotlight", "Índice do Spotlight", "Spotlight 索引", "Spotlight dizini", "Indeks Spotlight", "Spotlight-index"],
    "diagnostics.category.coreSpotlightIndex": ["Metadati di ricerca", "Metadados de pesquisa", "搜尋元資料", "Arama meta verileri", "Metadane wyszukiwania", "Zoekmetadata"],
    "diagnostics.category.developerIndex": ["Indice di sviluppo", "Índice de desenvolvimento", "開發工具索引", "Geliştirme dizini", "Indeks narzędzi deweloperskich", "Ontwikkelaarsindex"],
    "diagnostics.category.applicationDatabase": ["Database dell’app", "Banco de dados do app", "應用程式資料庫", "Uygulama veritabanı", "Baza danych aplikacji", "App-database"],
    "diagnostics.category.filesystemSnapshot": ["Snapshot APFS", "Snapshot do APFS", "APFS 快照", "APFS anlık görüntüsü", "Migawka APFS", "APFS-snapshot"],
    "diagnostics.category.systemCache": ["Cache di sistema", "Cache do sistema", "系統快取", "Sistem önbelleği", "Pamięć podręczna systemu", "Systeemcache"],
    "diagnostics.category.systemData": ["Dati di sistema", "Dados do sistema", "系統資料", "Sistem verileri", "Dane systemowe", "Systeemgegevens"],
    "diagnostics.category.userData": ["I tuoi dati", "Seus dados", "你的資料", "Verileriniz", "Twoje dane", "Jouw gegevens"],
    "diagnostics.category.unknown": ["Non classificato", "Sem classificação", "未分類", "Sınıflandırılmamış", "Bez kategorii", "Niet ingedeeld"],
    "diagnostics.status.cleanable": ["Pulibile", "Pode ser limpo", "可清理", "Temizlenebilir", "Do wyczyszczenia", "Op te ruimen"],
    "diagnostics.status.rebuildable": ["Ricreabile", "Pode ser reconstruído", "可以重建", "Yeniden oluşturulabilir", "Można odtworzyć", "Opnieuw op te bouwen"],
    "diagnostics.status.protected": ["Protetto", "Protegido", "受保護", "Korumalı", "Chronione", "Beschermd"],
    "diagnostics.status.unknown": ["Senza giudizio", "Sem avaliação", "無法判斷", "Değerlendirilmedi", "Bez oceny", "Niet beoordeeld"],
    "diagnostics.remediation.trash": ["Va nel Cestino dopo la tua conferma", "Vai para a Lixeira após a confirmação", "確認後移入垃圾桶", "Onayınızdan sonra Çöp Sepeti’ne taşınır", "Trafia do Kosza po potwierdzeniu", "Gaat na jouw bevestiging naar de Prullenbak"],
    "diagnostics.remediation.spotlight": ["Ricrea con Spotlight: mdutil -E", "Reconstruir com o Spotlight: mdutil -E", "用 Spotlight 重建：mdutil -E", "Spotlight ile yeniden oluşturun: mdutil -E", "Odbuduj przez Spotlight: mdutil -E", "Met Spotlight herbouwen: mdutil -E"],
    "diagnostics.remediation.owningApplication": ["Ricrea dallo strumento che l’ha creato", "Reconstruir pela ferramenta que o criou", "由產生它的工具重建", "Oluşturan araçla yeniden oluşturun", "Odbuduj w narzędziu, które go utworzyło", "Herbouwen in de tool die het maakte"],
    "diagnostics.remediation.inspectOnly": ["Solo informativo: Sift non interviene", "Apenas informativo: o Sift não o modifica", "僅供參考，Sift 不會處理", "Yalnızca bilgi: Sift dokunmaz", "Tylko informacyjnie: Sift nie zmienia", "Alleen ter info: Sift grijpt niet in"],
    "diagnostics.coverage.complete": ["Questo risultato copre tutto l’ambito richiesto.", "Este resultado cobre tudo o que foi pedido.", "本次結果涵蓋了全部請求的範圍。", "Bu sonuç istenen her şeyi kapsıyor.", "Ten wynik obejmuje cały żądany zakres.", "Dit resultaat dekt alles wat gevraagd is."],
    "diagnostics.coverage.partial": ["Parte dell’ambito non si è lasciata misurare: i totali sono un limite inferiore.", "Parte do escopo não pôde ser medida, então os totais são um limite inferior.", "部分範圍無法統計，因此合計只是下限。", "Kapsamın bir kısmı ölçülemediği için toplamlar alt sınırdır.", "Części zakresu nie udało się zmierzyć, więc sumy są dolnym ograniczeniem.", "Een deel van het bereik kon niet worden gemeten, de totalen zijn dus een ondergrens."],
    "diagnostics.coverage.permissionDenied": ["Alcune posizioni richiedono l’Accesso completo al disco per essere misurate.", "Alguns locais exigem o Acesso Total ao Disco para serem medidos.", "部分位置需要完全磁碟存取權限才能統計。", "Bazı konumların ölçülebilmesi Tam Disk Erişimi gerektiriyor.", "Niektóre lokalizacje wymagają pełnego dostępu do dysku, aby można je było zmierzyć.", "Sommige locaties hebben Volledige Schijftoegang nodig om gemeten te kunnen worden."],
    "diagnostics.coverage.volumeUnavailable": ["Un volume non è più disponibile e non è stato misurato.", "Um volume não está mais disponível e não foi medido.", "有一個卷宗已不可用，未做統計。", "Bir birim artık kullanılamıyor ve ölçülmedi.", "Jeden wolumen jest niedostępny i nie został zmierzony.", "Een volume is niet meer beschikbaar en is niet gemeten."],
    "diagnostics.explanation.volumeChild": ["Una directory al livello più alto del volume.", "Um diretório no nível mais alto do volume.", "卷宗根目錄下的一個目錄。", "Birim en üst düzeyinde bir dizin.", "Katalog na najwyższym poziomie wolumenu.", "Een map op het hoogste niveau van het volume."],
    "diagnostics.explanation.systemData": ["Parte di macOS o delle sue librerie. Occupa spazio e non si può rimuovere.", "Parte do macOS ou de suas bibliotecas. Ocupa espaço e não pode ser removida.", "屬於 macOS 或其系統程式庫。它佔用空間，但不能刪除。", "macOS’un veya kitaplıklarının bir parçası. Yer kaplar ve kaldırılamaz.", "Część macOS lub jego bibliotek. Zajmuje miejsce i nie można jej usunąć.", "Onderdeel van macOS of diens bibliotheken. Neemt ruimte in en kan niet verwijderd worden."],
    "diagnostics.explanation.spotlightIndexed": ["L’indice Spotlight di questo volume; l’indicizzazione è attiva. macOS lo ricrea con mdutil -E: spostarlo nel Cestino rende solo la ricerca indisponibile finché non è stato ricostruito.", "O índice do Spotlight deste volume; a indexação está ativada. O macOS o reconstrói com mdutil -E — movê-lo para a Lixeira apenas deixa a busca indisponível até ser reconstruído.", "此卷宗的 Spotlight 索引，索引服務目前已啟用。macOS 可用 mdutil -E 重建；直接移入垃圾桶只會讓搜尋在重建完成前不可用。", "Bu birimin Spotlight dizini; dizinleme açık. macOS bunu mdutil -E ile yeniden oluşturur — Çöp Sepeti’ne taşımak yalnızca yeniden oluşturulana kadar aramayı kullanılamaz hâle getirir.", "Indeks Spotlight tego wolumenu; indeksowanie jest włączone. macOS odbuduje go przez mdutil -E — przeniesienie do Kosza tylko na czas odbudowy wyłączy wyszukiwanie.", "De Spotlight-index van dit volume; indexeren staat aan. macOS herbouwt hem met mdutil -E — naar de Prullenbak verplaatsen maakt zoeken alleen onbruikbaar tot de herbouw klaar is."],
    "diagnostics.explanation.spotlightNotIndexed": ["L’indice Spotlight di questo volume; l’indicizzazione risulta spenta. La directory è gestita da macOS.", "O índice do Spotlight deste volume; a indexação figura como desativada. O diretório é gerenciado pelo macOS.", "此卷宗的 Spotlight 索引，目前索引服務處於關閉狀態。此目錄由 macOS 管理。", "Bu birimin Spotlight dizini; dizinleme şu anda kapalı görünüyor. Dizini macOS yönetir.", "Indeks Spotlight tego wolumenu; indeksowanie jest wyłączone. Katalogiem zarządza macOS.", "De Spotlight-index van dit volume; indexeren meldt zich als uit. Deze map wordt door macOS beheerd."],
    "diagnostics.explanation.spotlightStateUnknown": ["L’indice Spotlight di questo volume. Non è stato possibile leggere cosa sta facendo Spotlight in questo momento.", "O índice do Spotlight deste volume. Não foi possível ler o que o Spotlight está fazendo agora.", "此卷宗的 Spotlight 索引。無法讀取 Spotlight 目前的狀態。", "Bu birimin Spotlight dizini. Spotlight’ın şu anki durumu okunamadı.", "Indeks Spotlight tego wolumenu. Nie udało się odczytać, co Spotlight robi obecnie.", "De Spotlight-index van dit volume. Wat Spotlight nu doet kon niet worden gelezen."],
    "diagnostics.explanation.spotlightUnreadable": ["L’indice Spotlight di questo volume. Non è stata possibile leggere la dimensione: serve l’Accesso completo al disco.", "O índice do Spotlight deste volume. Não foi possível ler seu tamanho: é preciso o Acesso Total ao Disco.", "此卷宗的 Spotlight 索引。無法讀取它的大小：需要完全磁碟存取權限。", "Bu birimin Spotlight dizini. Boyutu okunamadı: Tam Disk Erişimi gerekiyor.", "Indeks Spotlight tego wolumenu. Nie udało się odczytać jego rozmiaru: wymagany pełny dostęp do dysku.", "De Spotlight-index van dit volume. De grootte kon niet worden gelezen: Volledige Schijftoegang is nodig."],
    "diagnostics.explanation.coreSpotlight": ["Metadati di ricerca che il sistema conserva per i tuoi contenuti, come mail e messaggi. Ricrearli richiede tempo e la ricerca resta incompleta finché non è finita.", "Metadados de pesquisa que o sistema guarda para seu conteúdo, como e-mail e mensagens. Reconstruí-los demora e a busca fica incompleta até terminar.", "系統為你的內容（郵件、訊息等）保存的搜尋元資料。重建可能耗時，重建期間搜尋不完整。", "Sistemin posta ve mesajlar gibi içerikleriniz için tuttuğu arama meta verileri. Yeniden oluşturmak zaman alır ve bitene kadar arama eksik kalır.", "Metadane wyszukiwania, które system przechowuje dla Twoich treści, jak poczta i wiadomości. Odbudowa trwa, a wyszukiwanie jest niekompletne, aż się skończy.", "Zoekmetadata die het systeem bijhoudt voor je eigen inhoud, zoals mail en berichten. Herbouwen kost tijd en zoeken is incompleet totdat het klaar is."],
    "diagnostics.explanation.coreSpotlightUnreadable": ["Metadati di ricerca che il sistema conserva per i tuoi contenuti. Non è stata possibile leggere la dimensione: serve l’Accesso completo al disco.", "Metadados de pesquisa que o sistema guarda para seu conteúdo. Não foi possível ler seu tamanho: é preciso o Acesso Total ao Disco.", "系統為你的內容保存的搜尋元資料。無法讀取它的大小：需要完全磁碟存取權限。", "Sistemin içerikleriniz için tuttuğu arama meta verileri. Boyutu okunamadı: Tam Disk Erişimi gerekiyor.", "Metadane wyszukiwania przechowywane dla Twoich treści. Rozmiaru nie udało się odczytać: wymagany pełny dostęp do dysku.", "Zoekmetadata voor je eigen inhoud. De grootte kon niet worden gelezen: Volledige Schijftoegang is nodig."],
    "diagnostics.explanation.developerIndex": ["Un indice costruito da uno strumento di sviluppo per questo progetto. Lo strumento lo ricrea su richiesta; fino ad allora completamento e ricerca di simboli sono più lenti.", "Um índice que uma ferramenta de desenvolvimento criou para este projeto. A ferramenta o reconstrói sob demanda; até lá, o autocompletar e a busca de símbolos ficam mais lentos.", "開發工具為此專案建立的索引。需要時該工具會重建；在重建前，程式碼補全和符號搜尋會更慢。", "Bir geliştirme aracının bu proje için oluşturduğu dizin. Araç gerektiğinde yeniden oluşturur; o ana kadar kod tamamlama ve simge araması yavaşlar.", "Indeks zbudowany przez narzędzie deweloperskie dla tego projektu. Narzędzie odbuduje go na żądanie; do tego czasu uzupełnianie i wyszukiwanie symboli są wolniejsze.", "Een index die een ontwikkeltool voor dit project bouwde. De tool herbouwt hem op verzoek; tot die tijd zijn aanvullen en symboolzoeken trager."],
    "diagnostics.explanation.developerData": ["Dati di build e cache che uno strumento di sviluppo conserva qui. Sift non giudica cosa un progetto possa ricreare, quindi qui nulla viene offerto per la rimozione.", "Dados de build e caches que uma ferramenta de desenvolvimento guarda aqui. O Sift não julga o que um projeto pode reconstruir, então nada daqui é oferecido para remoção.", "開發工具存放的建置資料和快取。Sift 無法判斷某個專案能重建什麼，因此這裡的內容不會被列為可刪除項。", "Bir geliştirme aracının burada tuttuğu derleme verileri ve önbellekler. Sift bir projenin neyi yeniden oluşturabileceğine hükmetmez, bu yüzden buradan kaldırılmak üzere bir şey önerilmez.", "Dane kompilacji i pamięci podręczne przechowywane przez narzędzie deweloperskie. Sift nie ocenia, co projekt może odtworzyć, więc nic stąd nie jest proponowane do usunięcia.", "Buildgegevens en caches die een ontwikkeltool hier bewaart. Sift oordeelt niet wat een project kan herbouwen, dus wordt hier niets aangeboden voor verwijdering."],
    "diagnostics.explanation.snapshots": ["Snapshot locali APFS. Conservano lo stato del volume, macOS li assottiglia da solo e il sistema non riporta la dimensione di ciascuno.", "Snapshots locais do APFS. Guardam o estado do volume, o macOS os reduz por conta própria e o sistema não informa o tamanho de cada um.", "APFS 本機快照。它們保存卷宗的狀態，macOS 會自動精簡，系統不提供單一快照的佔用大小。", "APFS yerel anlık görüntüleri. Birimin durumunu tutar, macOS bunları kendisi arındırır ve sistem her birinin boyutunu bildirmez.", "Lokalne migawki APFS. Przechowują stan wolumenu, macOS sam je przerzedza, a system nie podaje rozmiaru pojedynczej migawki.", "Lokale APFS-snapshots. Ze bewaren de volumestatus, macOS dunt ze zelf uit en het systeem meldt geen grootte per snapshot."],
    "diagnostics.coverage.note": ["Apri Impostazioni di Sistema, concedi l’Accesso completo al disco e ripeti l’analisi.", "Conceda o Acesso Total ao Disco nos Ajustes do Sistema e execute a análise novamente.", "在系統設定中授予完全磁碟存取權限，然後重新執行診斷。", "Sistem Ayarları’nda Tam Disk Erişimi verin ve tanıyı yeniden çalıştırın.", "Nadaj pełny dostęp do dysku w Ustawieniach systemowych i uruchom analizę ponownie.", "Geef Volledige Schijftoegang in Systeeminstellingen en voer de analyse opnieuw uit."],
    "diagnostics.section.protected": ["Protetti, ma grandi", "Protegido, mas volumoso", "受保護但佔用較大", "Korumalı ama büyük", "Chronione, ale duże", "Beschermd, maar groot"],
    "diagnostics.section.rebuildable": ["Ricreabili", "Podem ser reconstruídos", "可以重建", "Yeniden oluşturulabilir", "Można odtworzyć", "Opnieuw op te bouwen"],
    "diagnostics.section.snapshots": ["Snapshot", "Snapshots", "快照", "Anlık görüntüler", "Migawki", "Snapshots"],
    "diagnostics.section.skipped": ["Non si sono lasciati leggere", "Não puderam ser lidos", "無法讀取的位置", "Okunamayan konumlar", "Nie udało się odczytać", "Konden niet worden gelezen"],
    "diagnostics.empty": ["In questo ambito non è stato trovato nulla di grande.", "Nada voluminoso foi encontrado neste escopo.", "在此範圍內沒有發現佔用較大的內容。", "Bu kapsamda büyük bir şey bulunamadı.", "W tym zakresie nie znaleziono niczego dużego.", "In dit bereik werd niets groots gevonden."],
    "diagnostics.note.approximate": ["Le dimensioni sono stime: cloni e snapshot rendono lo spazio allocato non additivo.", "Os tamanhos são estimativas: clones e snapshots fazem o espaço alocado não ser aditivo.", "大小是估算值：克隆和快照會使分配空間不能簡單相加。", "Boyutlar tahminidir: klonlar ve anlık görüntüler ayrılan alanı toplanabilir yapmaz.", "Rozmiary są przybliżone: klony i migawki powodują, że zajętość nie sumuje się wprost.", "Groottes zijn schattingen: klonen en snapshots maken de toegewezen ruimte niet-additief."],
    "diagnostics.note.readOnly": ["La diagnostica legge soltanto. Qui nulla viene rimosso e una pulizia passa comunque dalla conferma normale.", "O diagnóstico apenas lê. Nada é removido aqui e qualquer limpeza passa pela confirmação habitual.", "診斷只做讀取。這裡的任何內容都不會被刪除；如要清理，仍會走正常的確認流程。", "Tanı yalnızca okur. Burada hiçbir şey kaldırılmaz ve temizlik yine normal onaydan geçer.", "Diagnostyka tylko odczytuje. Nic tu nie jest usuwane, a czyszczenie nadal przechodzi zwykłe potwierdzenie.", "Diagnostiek leest alleen. Hier wordt niets verwijderd en opschonen gaat nog steeds via de normale bevestiging."],
    "files.manageScope": ["Gestisci nelle Impostazioni", "Gerenciar nos Ajustes", "在設定中管理", "Ayarlar’da yönet", "Zarządzaj w ustawieniach", "Beheer in Instellingen"],
    "settings.group.authorized": ["Cartelle autorizzate", "Pastas autorizadas", "已授權資料夾", "Yetkilendirilmiş klasörler", "Foldery z autoryzacją", "Geautoriseerde mappen"],
    "settings.authorized.empty": ["Non hai ancora autorizzato nulla. Le cartelle aggiunte qui vengono scansionate e usate per trovare i duplicati.", "Nada foi autorizado ainda. As pastas adicionadas aqui são verificadas e usadas para encontrar duplicados.", "尚未授權任何位置。在此加入的資料夾會被掃描，並用於尋找重複檔案。", "Henüz bir şey yetkilendirilmedi. Buraya eklenen klasörler taranır ve kopya aramada kullanılır.", "Jeszcze nic nie zostało autoryzowane. Dodane tu foldery są skanowane i używane do wyszukiwania duplikatów.", "Er is nog niets geautoriseerd. Mappen die je hier toevoegt worden gescand en gebruikt om duplicaten te vinden."],
    "settings.staleThreshold": ["Soglia di obsolescenza", "Limite de obsolescência", "過期閾值", "Bayatlık eşiği", "Próg nieaktualności", "Verouderingsdrempel"],
    "storage.includeVolume": ["Includi la diagnostica dell’intero volume", "Incluir diagnóstico do volume inteiro", "包含整卷診斷", "Tüm birim tanısını dahil et", "Uwzględnij diagnostykę całego wolumenu", "Diagnostiek van het hele volume opnemen"],
    "storage.scopeNote": ["Le categorie di file coprono la tua cartella home e le cartelle autorizzate su questo disco. L’interruttore aggiunge la diagnostica dell’intero volume.", "As categorias de arquivos cobrem sua pasta pessoal e as pastas autorizadas neste disco. A opção adiciona o diagnóstico do volume inteiro.", "檔案分類統計個人資料夾和此磁碟上已授權的資料夾；開關會為系統診斷加入整卷範圍。", "Dosya kategorileri ana klasörünüzü ve bu diskteki yetkilendirilmiş klasörleri kapsar. Anahtar, sistem tanısına tüm birimi ekler.", "Kategorie plików obejmują Twój folder domowy i autoryzowane foldery na tym dysku. Przełącznik dodaje diagnostykę całego wolumenu.", "Bestandscategorieën dekken je persoonlijke map en geautoriseerde mappen op deze schijf. De schakelaar voegt systeemdiagnostiek van het hele volume toe."],
    "settings.authorized.unavailable": ["Non disponibile in questa sessione", "Indisponível nesta sessão", "本次工作階段不可用", "Bu oturumda kullanılamıyor", "Niedostępne w tej sesji", "Niet beschikbaar in deze sessie"],
    "files.scopeTitle": ["Cartelle che hai aggiunto", "Pastas que você adicionou", "你加入的資料夾", "Eklediğiniz klasörler", "Foldery, które dodałeś", "Mappen die je toevoegde"],
    "settings.removeLicense": ["Rimuovi la chiave di licenza salvata", "Remover a chave de licença salva", "移除已儲存的授權碼", "Kayıtlı lisans anahtarını kaldır", "Usuń zapisany klucz licencji", "Opgeslagen licentiesleutel verwijderen"],

    # --- Storage -----------------------------------------------------------
    "storage.title": ["Archiviazione", "Armazenamento", "儲存空間", "Depolama", "Pamięć masowa", "Opslag"],
    "storage.used": ["%@ usati su %@", "%@ usados de %@", "已使用 %@ / %@", "%@ / %@ kullanıldı", "%@ zajęte z %@", "%@ gebruikt van %@"],
    "storage.byType": ["Per tipo di file", "Por tipo de arquivo", "按類型", "Dosya türüne göre", "Według typu pliku", "Per bestandstype"],
    "storage.type.images": ["Immagini", "Imagens", "影像", "Görseller", "Obrazy", "Afbeeldingen"],
    "storage.type.video": ["Video", "Vídeo", "影片", "Video", "Wideo", "Video"],
    "storage.type.audio": ["Audio", "Áudio", "音訊", "Ses", "Audio", "Audio"],
    "storage.type.documents": ["Documenti", "Documentos", "文件", "Belgeler", "Dokumenty", "Documenten"],
    "storage.type.archives": ["Archivi", "Arquivos compactados", "壓縮檔", "Arşivler", "Archiwa", "Archieven"],
    "storage.type.code": ["Codice", "Código", "程式碼", "Kod", "Kod", "Code"],
    "storage.type.data": ["Dati", "Dados", "資料", "Veri", "Dane", "Gegevens"],
    "storage.type.other": ["Altro", "Outros", "其他", "Diğer", "Inne", "Overig"],
    "storage.topFiles": ["File più grandi", "Arquivos maiores", "最大檔案", "En büyük dosyalar", "Największe pliki", "Grootste bestanden"],
    "storage.topDirectories": ["Cartelle più grandi", "Pastas maiores", "最大目錄", "En büyük klasörler", "Największe foldery", "Grootste mappen"],
    "storage.analyze": ["Analizza l’archiviazione", "Analisar armazenamento", "分析儲存空間", "Depolamayı analiz et", "Analizuj pamięć masową", "Opslag analyseren"],
    "storage.start": ["Avvia l’analisi", "Iniciar análise", "開始分析", "Analizi başlat", "Rozpocznij analizę", "Analyse starten"],
    "storage.reanalyze": ["Analizza di nuovo", "Analisar novamente", "重新分析", "Yeniden analiz et", "Analizuj ponownie", "Opnieuw analyseren"],
    "storage.cancelAnalysis": ["Annulla l’analisi", "Cancelar análise", "取消分析", "Analizi iptal et", "Anuluj analizę", "Analyse annuleren"],
    "storage.lastAnalyzed": ["Ultima analisi: %@", "Última análise: %@", "上次分析：%@", "Son analiz: %@", "Ostatnia analiza: %@", "Laatst geanalyseerd: %@"],
    "storage.analysing": ["Analisi in corso…", "Analisando…", "分析中…", "Analiz ediliyor…", "Analizowanie…", "Analyseren…"],
    "storage.diskDisconnected": ["Questo disco non è più collegato. Ricollegalo e scansiona di nuovo.", "Este disco não está mais conectado. Reconecte-o e verifique novamente.", "此磁碟已斷開連接。請重新連接後再掃描。", "Bu disk artık bağlı değil. Yeniden bağlayın ve yeniden tarayın.", "Ten dysk nie jest już podłączony. Podłącz go ponownie i skanuj jeszcze raz.", "Deze schijf is niet meer verbonden. Sluit hem opnieuw aan en scan opnieuw."],
    "storage.noAccess": ["Sift non riesce ancora a leggere questa posizione.", "O Sift ainda não consegue ler esta localização.", "Sift 還無法讀取此位置。", "Sift henüz bu konumu okuyamıyor.", "Sift nie potrafi jeszcze odczytać tej lokalizacji.", "Sift kan deze locatie nog niet lezen."],

    # --- Settings ----------------------------------------------------------
    "settings.title": ["Impostazioni", "Ajustes", "設定", "Ayarlar", "Ustawienia", "Instellingen"],
    "settings.group.scanScope": ["Ambito di scansione", "Escopo da verificação", "掃描範圍", "Tarama kapsamı", "Zakres skanowania", "Scankbereik"],
    "settings.group.thresholds": ["Soglie", "Limites", "閾值", "Eşikler", "Progi", "Drempels"],
    "settings.group.ignores": ["Elementi ignorati", "Itens ignorados", "忽略列表", "Yoksayılanlar", "Elementy ignorowane", "Genegeerde items"],
    "settings.group.confirmation": ["Conferma", "Confirmação", "確認", "Onay", "Potwierdzenie", "Bevestiging"],
    "settings.group.appearance": ["Aspetto", "Aparência", "外觀", "Görünüm", "Wygląd", "Uiterlijk"],
    "settings.group.language": ["Lingua", "Idioma", "語言", "Dil", "Język", "Taal"],
    "settings.group.privacy": ["Privacy", "Privacidade", "隱私權", "Gizlilik", "Prywatność", "Privacy"],
    "settings.group.purchase": ["Acquisto", "Compra", "購買狀態", "Satın alma", "Zakup", "Aankoop"],
    "settings.group.logs": ["Diagnostica", "Diagnósticos", "診斷", "Tanılama", "Diagnostyka", "Diagnostiek"],
    "settings.largeFileThreshold": ["Soglia file grandi", "Limite de arquivos grandes", "大型檔案閾值", "Büyük dosya eşiği", "Próg dużych plików", "Drempel voor grote bestanden"],
    "settings.oldFileThreshold": ["Soglia file datati", "Limite de arquivos antigos", "舊檔案閾值", "Eski dosya eşiği", "Próg starych plików", "Drempel voor oude bestanden"],
    "settings.days": ["%d giorni", "%d dias", "%d 天", "%d gün", "%d dni", "%d dagen"],
    "settings.showHiddenFiles": ["Mostra i file nascosti nei risultati", "Mostrar arquivos ocultos nos resultados", "結果顯示隱藏檔案", "Sonuçlarda gizli dosyaları göster", "Pokazuj ukryte pliki w wynikach", "Toon verborgen bestanden in resultaten"],
    "settings.userRules": ["Usa un file di regole personalizzato", "Usar um arquivo de regras personalizado", "使用自訂規則檔案", "Özel kural dosyası kullan", "Użyj własnego pliku reguł", "Eigen regelsbestand gebruiken"],
    "settings.userRulesDetail": ["Legge CleaningRules.json dalla cartella dati dell’app. Vale dalla prossima scansione.", "Lê CleaningRules.json da pasta de dados do app. Vale a partir da próxima verificação.", "從應用程式資料目錄讀取 CleaningRules.json，下一次掃描生效。", "Uygulamanın veri klasöründen CleaningRules.json dosyasını okur. Sonraki taramadan itibaren geçerlidir.", "Czyta CleaningRules.json z folderu danych aplikacji. Obowiązuje od następnego skanowania.", "Leest CleaningRules.json uit de datamap van de app. Geldt vanaf de volgende scan."],
    "settings.requireConfirmation": ["Chiedi conferma prima di pulire", "Pedir confirmação antes de limpar", "清理前要求確認", "Temizlemeden önce onay iste", "Proś o potwierdzenie przed czyszczeniem", "Om bevestiging vragen vóór het opschonen"],
    "settings.skipConfirmation": ["Salta la conferma", "Pular confirmação", "略過確認", "Onayı atla", "Pomiń potwierdzenie", "Bevestiging overslaan"],
    "settings.skipConfirmationWarning": ["Sift inizia a pulire appena clicchi. Gli elementi vanno comunque nel Cestino, ma non vedrai prima l’elenco. Gli elementi da verificare mostrano sempre l’elenco.", "O Sift começa a limpar assim que você clicar. Os itens ainda vão para a Lixeira, mas você não verá a lista antes. Itens marcados para revisão sempre mostram a lista.", "點按後 Sift 會立即開始清理。項目仍會移入垃圾桶，但不會先顯示清單。標記為需確認的項目一律會顯示清單。", "Sift tıkladığınız anda temizlemeye başlar. Öğeler yine Çöp Sepeti’ne gider, ama listeyi önce görmezsiniz. Kontrol edilmesi işaretli öğeler listeyi her zaman gösterir.", "Sift zacznie czyścić od razu po kliknięciu. Elementy nadal trafiają do Kosza, ale nie zobaczysz najpierw listy. Elementy oznaczone do sprawdzenia zawsze pokazują listę.", "Sift begint meteen met opschonen zodra je klikt. Items gaan nog steeds naar de Prullenbak, maar je ziet de lijst niet eerst. Items die om controle vragen tonen altijd de lijst."],
    "settings.appearance.system": ["Come il sistema", "Conforme o sistema", "跟隨系統", "Sistemi izle", "Jak w systemie", "Volg systeem"],
    "settings.appearance.light": ["Chiaro", "Claro", "淺色", "Açık", "Jasny", "Licht"],
    "settings.appearance.dark": ["Scuro", "Escuro", "深色", "Koyu", "Ciemny", "Donker"],
    "settings.reduceMotion": ["Riduci movimento", "Reduzir movimento", "減少動態效果", "Hareketi azalt", "Ogranicz ruch", "Beweging verminderen"],
    "settings.privacyStatement": ["Sift non raccoglie contenuti dei file, nomi dei file, percorsi completi, cronologia di navigazione, uso delle app o dati dell’account. I risultati della scansione restano su questo Mac e nulla viene caricato online.", "O Sift não coleta conteúdos de arquivos, nomes, caminhos completos, histórico de navegação, uso de apps ou dados de conta. Os resultados da verificação ficam neste Mac, e nada é enviado.", "Sift 不蒐集檔案內容、檔名、完整路徑、瀏覽記錄、應用程式使用記錄或帳號資訊。掃描結果只保存在本機，不會上傳。", "Sift; dosya içeriklerini, dosya adlarını, tam yolları, tarama geçmişini, uygulama kullanımını veya hesap bilgilerini toplamaz. Tarama sonuçları bu Mac’te kalır, hiçbir şey yüklenmez.", "Sift nie zbiera treści plików, ich nazw, pełnych ścieżek, historii przeglądania, użycia aplikacji ani danych konta. Wyniki skanowania zostają na tym Macu, nic nie jest wysyłane.", "Sift verzamelt geen bestandsinhoud, bestandsnamen, volledige paden, browsegeschiedenis, app-gebruik of accountgegevens. Scanresultaten blijven op deze Mac, er wordt niets geüpload."],
    "settings.exportLogs": ["Esporta la diagnostica", "Exportar diagnósticos", "輸出診斷資訊", "Tanılama verilerini dışa aktar", "Wyeksportuj diagnostykę", "Diagnostiek exporteren"],
    "settings.exportLogsDetail": ["La diagnostica non contiene nomi di file né percorsi completi.", "Os diagnósticos não contêm nomes de arquivos nem caminhos completos.", "診斷資訊不包含檔名或完整路徑。", "Tanılama verileri dosya adı veya tam yol içermez.", "Diagnostyka nie zawiera nazw plików ani pełnych ścieżek.", "Diagnostiek bevat geen bestandsnamen of volledige paden."],
    "settings.clearHistory": ["Cancella la cronologia scansioni", "Limpar histórico de verificações", "清除掃描記錄", "Tarama geçmişini temizle", "Wyczyść historię skanowań", "Scangeschiedenis wissen"],
    "settings.deleteReports": ["Elimina i rapporti salvati", "Excluir relatórios salvos", "刪除已儲存的報告", "Kayıtlı raporları sil", "Usuń zapisane raporty", "Opgeslagen rapporten verwijderen"],
    "settings.deleteReportsConfirm": ["Eliminare tutti i rapporti PDF salvati? L’operazione non si può annullare.", "Excluir todos os relatórios PDF salvos? Esta ação não pode ser desfeita.", "刪除所有已儲存的 PDF 報告？此操作無法復原。", "Kayıtlı tüm PDF raporları silinsin mi? Bu işlem geri alınamaz.", "Usunąć wszystkie zapisane raporty PDF? Tej czynności nie można cofnąć.", "Alle opgeslagen PDF-rapporten verwijderen? Dit kan niet ongedaan worden gemaakt."],
    "settings.resetDefaults": ["Ripristina predefiniti", "Restaurar padrões", "回復預設設定", "Varsayılanları geri yükle", "Przywróć domyślne", "Standaarden herstellen"],

    # --- Purchase ----------------------------------------------------------
    "purchase.title": ["Sblocca Sift", "Desbloquear o Sift", "解鎖 Sift", "Sift’i Aç", "Odblokuj Sift", "Sift ontgrendelen"],
    "purchase.priceLine": ["4,99 $ una volta, per sempre, senza abbonamento", "US$ 4,99 uma vez, para sempre, sem assinatura", "$4.99 一次買斷，永久使用，無訂閱", "4,99 $ bir kez, süresiz, abonelik yok", "4,99 $ raz, na zawsze, bez subskrypcji", "$4,99 eenmalig, voor altijd, geen abonnement"],
    "purchase.updatesPromise": ["Include i futuri aggiornamenti principali.", "Inclui futuras atualizações importantes.", "包含未來大版本更新。", "Gelecekteki büyük güncellemeleri içerir.", "Obejmuje przyszłe duże aktualizacje.", "Inclusief toekomstige grote updates."],
    "purchase.freeTier.scan": ["Scansionare tutto il Mac", "Verificar o Mac inteiro", "掃描整台 Mac", "Tüm Mac’i taramak", "Przeskanować cały Mac", "Je hele Mac scannen"],
    "purchase.freeTier.explain": ["Vedere ogni elemento, la sua origine e il suo rischio", "Ver cada item, sua origem e seu risco", "查看每個項目的來源和風險", "Her öğeyi, kaynağını ve riskini görmek", "Zobaczyć każdy element, jego źródło i ryzyko", "Elk item, de bron en het risico zien"],
    "purchase.freeTier.estimate": ["Vedere quanto spazio puoi liberare", "Ver quanto espaço você pode liberar", "查看可釋放空間估算", "Ne kadar alan kazanabileceğinizi görmek", "Zobaczyć, ile miejsca można odzyskać", "Zien hoeveel ruimte je kunt vrijmaken"],
    "purchase.freeTier.storage": ["Analizzare l’archiviazione per tipo e cartella", "Analisar o armazenamento por tipo e pasta", "按類型和目錄分析儲存空間", "Depolamayı tür ve klasöre göre analiz etmek", "Analizować pamięć według typu i folderu", "Opslag analyseren per type en map"],
    "purchase.paidTierTitle": ["Cosa aggiunge lo sblocco", "O que o desbloqueio adiciona", "解鎖後新增", "Açma ne ekler", "Co daje odblokowanie", "Wat ontgrendelen toevoegt"],
    "purchase.paidTier.clean": ["Spostare cache, log e installer nel Cestino", "Mover caches, logs e instaladores para a Lixeira", "將快取、記錄檔和安裝程式移入垃圾桶", "Önbellek, günlük ve yükleyicileri Çöp Sepeti’ne taşımak", "Przenosić pamięci podręczne, dzienniki i instalatory do Kosza", "Caches, logbestanden en installatieprogramma’s naar de Prullenbak verplaatsen"],
    "purchase.paidTier.uninstall": ["Disinstallare le app con i file correlati", "Desinstalar apps com seus arquivos relacionados", "連同相關檔案解除安裝應用程式", "Uygulamaları ilgili dosyalarıyla kaldırmak", "Odinstalowywać aplikacje wraz z plikami powiązanymi", "Apps verwijderen samen met hun gerelateerde bestanden"],
    "purchase.paidTier.files": ["Pulire file grandi, datati e duplicati", "Limpar arquivos grandes, antigos e duplicados", "清理大型、舊的和重複的檔案", "Büyük, eski ve kopya dosyaları temizlemek", "Czyścić duże, stare i duplikaty plików", "Grote, oude en dubbele bestanden opschonen"],
    "purchase.paidTier.report": ["Rapporti completi di pulizia ed esportazione PDF", "Relatórios completos de limpeza e exportação em PDF", "完整清理報告和 PDF 輸出", "Eksiksiz temizlik raporları ve PDF dışa aktarma", "Pełne raporty czyszczenia i eksport PDF", "Volledige opschoningsrapporten en PDF-export"],
    "purchase.activateLicense": ["Inserisci la chiave di licenza", "Digite a chave de licença", "輸入授權碼", "Lisans anahtarını girin", "Wpisz klucz licencji", "Licentiesleutel invoeren"],
    "purchase.restore": ["Ripristina acquisto", "Restaurar compra", "回復購買", "Satın almayı geri yükle", "Przywróć zakup", "Aankoop herstellen"],
    "purchase.restored": ["Acquisto ripristinato. La pulizia è sbloccata.", "Compra restaurada. A limpeza está desbloqueada.", "已回復購買。清理功能已解鎖。", "Satın alma geri yüklendi. Temizlik açıldı.", "Zakup przywrócony. Czyszczenie odblokowane.", "Aankoop hersteld. Opschonen is ontgrendeld."],
    "purchase.activated": ["Licenza attivata. Grazie!", "Licença ativada. Obrigado!", "授權已啟用，謝謝！", "Lisans etkinleştirildi. Teşekkürler!", "Licencja aktywowana. Dziękujemy!", "Licentie geactiveerd. Bedankt!"],
    "purchase.failed": ["Non siamo riusciti a completare l’operazione. Riprova.", "Não foi possível concluir. Tente novamente.", "操作未能完成，請重試。", "İşlem tamamlanamadı. Lütfen yeniden deneyin.", "Nie udało się zakończyć. Spróbuj ponownie.", "We konden dit niet voltooien. Probeer het opnieuw."],
    "purchase.networkUnavailable": ["Il servizio di acquisto non è raggiungibile. La tua licenza resta per ora utilizzabile offline.", "Não foi possível contatar o serviço de compra. Sua licença continua funcionando offline por enquanto.", "無法連接購買服務。你的授權目前仍可離線使用。", "Satın alma hizmetine ulaşılamadı. Lisansınız şimdilik çevrimdışı kullanılabilir.", "Usługa zakupów jest nieosiągalna. Twoja licencja na razie działa offline.", "De aankoopdienst is niet bereikbaar. Je licentie blijft voorlopig offline bruikbaar."],
    "purchase.licenseRequired": ["Sblocca Sift per pulire", "Desbloqueie o Sift para limpar", "解鎖 Sift 以執行清理", "Temizlemek için Sift’i açın", "Odblokuj Sift, aby czyścić", "Ontgrendel Sift om op te ruimen"],
    "purchase.licenseRequiredDetail": ["Scansione, analisi e anteprime restano gratis. Pulizia e disinstallazione richiedono l’acquisto una tantum.", "Verificação, análise e prévia continuam grátis. Limpar e desinstalar exigem a compra única.", "掃描、分析和預覽始終免費。清理和解除安裝需要一次性購買。", "Tarama, analiz ve önizleme ücretsiz kalır. Temizlik ve kaldırma tek seferlik satın alma gerektirir.", "Skanowanie, analiza i podglądy pozostają bezpłatne. Czyszczenie i odinstalowanie wymagają jednorazowego zakupu.", "Scannen, analyseren en bekijken blijven gratis. Opschonen en verwijderen vergen eenmalige aankoop."],
    "purchase.offlineGrace": ["Periodo di tolleranza offline: %d giorni rimasti", "Período offline: %d dias restantes", "離線寬限期還剩 %d 天", "Çevrimdışı telafi süresi: %d gün kaldı", "Okres offline: zostało %d dni", "Offline-graceperiode: nog %d dagen"],
    "purchase.status.purchased": ["Acquistato", "Comprado", "已購買", "Satın alındı", "Kupiono", "Gekocht"],
    "purchase.status.free": ["Versione gratuita", "Versão gratuita", "免費版", "Ücretsiz sürüm", "Wersja bezpłatna", "Gratis versie"],
    "nav.account": ["Account", "Conta", "帳戶", "Hesap", "Konto", "Account"],
    "account.activatedAt": ["Data di attivazione", "Data de ativação", "啟用時間", "Etkinleştirme tarihi", "Data aktywacji", "Geactiveerd op"],
    "account.licenseKey": ["Chiave di licenza", "Chave de licença", "授權碼", "Lisans anahtarı", "Klucz licencji", "Licentiesleutel"],
    # --- Report ------------------------------------------------------------
    "report.title": ["Rapporto di pulizia", "Relatório de limpeza", "清理報告", "Temizlik raporu", "Raport czyszczenia", "Opschoonrapport"],
    "report.generatedAt": ["Generato %@", "Gerado em %@", "產生時間 %@", "Oluşturulma: %@", "Wygenerowano %@", "Gegenereerd %@"],
    "report.appVersion": ["Sift %@ su macOS %@", "Sift %@ no macOS %@", "Sift %@，macOS %@", "Sift %@, macOS %@", "Sift %@ na macOS %@", "Sift %@ op macOS %@"],
    "report.scope": ["Cosa è stato scansionato", "O que foi verificado", "掃描範圍摘要", "Ne tarandı", "Co było skanowane", "Wat er gescand is"],
    "report.scopeDetail": ["%d posizioni, %d file esaminati", "%d locais, %d arquivos examinados", "%d 個位置，檢查 %d 個檔案", "%d konum, %d dosya incelendi", "%d lokalizacji, %d plików sprawdzonych", "%d locaties, %d bestanden onderzocht"],
    "report.categories": ["Categorie trattate", "Categorias tratadas", "處理的分類", "İşlenen kategoriler", "Obsługiwane kategorie", "Afgehandelde categorieën"],
    "report.status": ["Stato", "Estado", "狀態", "Durum", "Status", "Status"],
    "report.status.moved": ["Spostato nel Cestino", "Movido para a Lixeira", "已移入垃圾桶", "Çöp Sepeti’ne taşındı", "Przeniesiono do Kosza", "Naar de Prullenbak verplaatst"],
    "report.status.skipped": ["Ignorato", "Ignorado", "已略過", "Atlandı", "Pominięto", "Overgeslagen"],
    "report.status.failed": ["Non completato", "Não concluído", "未完成", "Tamamlanmadı", "Nie ukończono", "Niet voltooid"],
    "report.moved": ["Spostato nel Cestino", "Movido para a Lixeira", "成功移入垃圾桶", "Çöp Sepeti’ne taşındı", "Przeniesiono do Kosza", "Naar de Prullenbak verplaatst"],
    "report.movedDetail": ["%d elementi, %@", "%d itens, %@", "%d 個項目，%@", "%d öğe, %@", "%d elementów, %@", "%d items, %@"],
    "report.released": ["Spazio liberato", "Espaço liberado", "預計釋放空間", "Kazanılan alan", "Odzyskane miejsce", "Vrijgemaakt ruimte"],
    "report.skipped": ["Ignorati", "Ignorados", "略過項目", "Atlananlar", "Pominięte", "Overgeslagen"],
    "report.skippedDetail": ["Ignorati %d elementi. Vengono mostrati i primi 20.", "%d itens foram ignorados. Mostrando os primeiros 20.", "略過 %d 個項目，最多列出前 20 個。", "%d öğe atlandı. İlk 20 tanesi gösteriliyor.", "Pominięto %d elementów. Pokazano pierwsze 20.", "%d items overgeslagen. De eerste 20 worden getoond."],
    "report.failed": ["Non completati", "Não concluídos", "未完成項目", "Tamamlanmayanlar", "Nie ukończone", "Niet voltooid"],
    "report.failedDetail": ["%d elementi, vedi i dettagli sotto", "%d itens, veja os detalhes abaixo", "%d 個項目，詳見下方", "%d öğe, ayrıntılar aşağıda", "%d elementów, szczegóły poniżej", "%d items, details hieronder"],
    "report.privacyNote": ["Questo rapporto elenca solo categorie e dimensioni. Non contiene nomi di file, percorsi né contenuti.", "Este relatório lista apenas categorias e tamanhos. Não contém nomes de arquivos, caminhos nem conteúdos.", "本報告只列出分類和大小，不包含檔名、路徑或檔案內容。", "Bu rapor yalnızca kategori ve boyutları listeler. Dosya adı, yol veya içerik içermez.", "Ten raport wymienia tylko kategorie i rozmiary. Nie zawiera nazw plików, ścieżek ani treści.", "Dit rapport noemt alleen categorieën en groottes. Het bevat geen bestandsnamen, paden of inhoud."],
    "report.exportFailed": ["Il rapporto non si è lasciato salvare. La copia locale resta disponibile: puoi riprovare.", "O relatório não pôde ser salvo. A cópia local continua disponível para nova tentativa.", "報告儲存失敗。本機報告仍然保留，可以重試。", "Rapor kaydedilemedi. Yerel kopya duruyor; yeniden deneyebilirsiniz.", "Nie udało się zapisać raportu. Lokalna kopia pozostała, można spróbować ponownie.", "Het rapport kon niet worden opgeslagen. De lokale kopie blijft bestaan; probeer het opnieuw."],

    # --- Permissions -------------------------------------------------------
    "permission.fullDiskAccess": ["Accesso completo al disco", "Acesso Total ao Disco", "完全磁碟存取權限", "Tam Disk Erişimi", "Pełny dostęp do dysku", "Volledige Schijftoegang"],
    "permission.fullDiskAccessDetail": ["Sift scansiona cache e log anche senza. Concedendo l’Accesso completo al disco legge anche i log di sistema e le cartelle di supporto delle app.", "O Sift verifica caches e logs sem isso. Ao conceder o Acesso Total ao Disco, ele também lê logs do sistema e pastas de suporte dos apps.", "Sift 無需該權限也能掃描快取和記錄檔。授予完全磁碟存取權限後，還可讀取系統記錄檔和應用程式支援目錄。", "Sift bu izin olmadan da önbellek ve günlükleri tarar. İzin verilirse sistem günlüklerini ve uygulama destek klasörlerini de okur.", "Sift skanuje pamięci podręczne i dzienniki bez tego. Po nadaniu pełnego dostępu do dysku czyta także dzienniki systemowe i foldery aplikacji.", "Sift scant caches en logbestanden ook zonder. Met Volledige Schijftoegang leest het ook systeemlogbestanden en app-ondersteuningsmappen."],
    "permission.partialAccess": ["Alcune posizioni non si sono lasciate leggere", "Alguns locais não puderam ser lidos", "部分位置無法存取", "Bazı konumlar okunamadı", "Niektóre lokalizacje nieczytelne", "Sommige locaties konden niet worden gelezen"],
    "permission.openSettings": ["Apri Impostazioni di Sistema", "Abrir Ajustes do Sistema", "打開系統設定", "Sistem Ayarları’nı aç", "Otwórz Ustawienia systemowe", "Open Systeeminstellingen"],
    "permission.grantLater": ["Continua senza", "Continuar sem ela", "暫不授權，繼續", "Onay olmadan sürdür", "Kontynuuj bez tego", "Verder zonder"],

    "settings.diagnostics.scannerCore": ["Motore di scansione", "Núcleo de verificação", "掃描核心", "Tarama çekirdeği", "Rdzeń skanujący", "Scankern"],
    "settings.diagnostics.version": ["Versione", "Versão", "版本", "Sürüm", "Wersja", "Versie"],
    "settings.diagnostics.macOS": ["macOS", "macOS", "macOS", "macOS", "macOS", "macOS"],

    # --- Common ------------------------------------------------------------
    "common.done": ["Fine", "Concluído", "完成", "Bitti", "Gotowe", "Gereed"],
    "common.close": ["Chiudi", "Fechar", "關閉", "Kapat", "Zamknij", "Sluiten"],
    "common.remove": ["Rimuovi", "Remover", "移除", "Kaldır", "Usuń", "Verwijderen"],
    "common.unknownError": ["Non ha funzionato. Riprova.", "Não funcionou. Tente novamente.", "沒有成功，請再試一次。", "İşe yaramadı. Yeniden deneyin.", "Nie udało się. Spróbuj ponownie.", "Dat werkte niet. Probeer het opnieuw."],
    "common.fileCount": ["%d file", "%d arquivos", "%d 個檔案", "%d dosya", "%d plików", "%d bestanden"],
    "common.itemCount": ["%d elementi", "%d itens", "%d 個項目", "%d öğe", "%d elementów", "%d items"],
    "common.notAvailable": ["Non disponibile", "Indisponível", "不可用", "Kullanılamıyor", "Niedostępne", "Niet beschikbaar"],
    "common.loadMore": ["Carica altri", "Carregar mais", "載入更多", "Daha fazla yükle", "Wczytaj więcej", "Meer laden"],
    "common.retry": ["Riprova", "Tentar novamente", "重試", "Yeniden dene", "Ponów próbę", "Opnieuw proberen"],
    "common.of": ["%@ di %@", "%@ de %@", "%@ / %@", "%@ / %@", "%@ z %@", "%@ van %@"],
    "common.size": ["Dimensione", "Tamanho", "大小", "Boyut", "Rozmiar", "Grootte"],
    "common.risk": ["Rischio", "Risco", "風險等級", "Risk", "Ryzyko", "Risico"],
    "common.quitApp": ["Chiudi l’app", "Encerrar app", "結束應用程式", "Uygulamayı kapat", "Zamknij aplikację", "App afsluiten"],
    "common.loading": ["Caricamento…", "Carregando…", "載入中…", "Yükleniyor…", "Wczytywanie…", "Laden…"],
    "common.sortBy": ["Ordina per", "Ordenar por", "排序方式", "Sıralama ölçütü", "Sortuj według", "Sorteer op"],
    # --- Redesigned navigation, overview, scan, apps and storage -----------
    "nav.scan": ["Scansione", "Verificação", "掃描", "Tarama", "Skanowanie", "Scan"],
    "nav.apps": ["App", "Apps", "應用程式", "Uygulamalar", "Aplikacje", "Apps"],

    "overview.scanScope": ["Cosa copre una scansione", "O que a verificação cobre", "可掃描的內容", "Tarama neleri kapsar", "Co obejmuje skanowanie", "Wat een scan dekt"],
    "overview.status": ["%@", "%@", "%@", "%@", "%@", "%@"],
    "overview.reclaimable.title": ["Liberabile senza rischi", "Seguro para liberar", "本次可安全釋放", "Güvenle kazanılabilir", "Bezpieczne do odzyskania", "Veilig vrij te maken"],
    "overview.reclaimable.breakdown": ["%@ è sicuro, %@ richiede la tua conferma", "%@ é seguro, %@ requer sua confirmação", "其中 %@ 為安全項目，%@ 需要你確認後清理", "%@ güvenli, %@ onayınızı gerektiriyor", "%@ jest bezpieczne, %@ wymaga potwierdzenia", "%@ is veilig, %@ vraagt om jouw bevestiging"],
    "overview.reclaimable.meta": ["%d categorie, %d elementi", "%d categorias, %d itens", "%d 類，%d 項", "%d kategori, %d öğe", "%d kategorie, %d elementów", "%d categorieën, %d items"],
    "overview.ready": ["Pronto per la scansione", "Pronto para verificar", "準備就緒", "Taramaya hazır", "Gotowe do skanowania", "Klaar om te scannen"],
    "overview.noResults": ["Esegui una scansione per vedere cosa puoi liberare in sicurezza.", "Execute uma verificação para ver o que pode ser liberado com segurança.", "掃描後，這裡會顯示可以安全釋放的空間。", "Güvenle kazanabileceklerinizi görmek için tarama yapın.", "Uruchom skanowanie, aby zobaczyć, co można bezpiecznie odzyskać.", "Voer een scan uit om te zien wat er veilig vrijgemaakt kan worden."],
    "overview.viewProgress": ["Vedi l’avanzamento", "Ver o progresso", "查看掃描進度", "Tarama ilerlemesini gör", "Pokaż postęp skanowania", "Scanvoortgang bekijken"],
    "overview.noCleanup": ["Ancora nessuna pulizia", "Ainda nenhuma limpeza", "還沒有清理記錄", "Henüz temizlik yok", "Jeszcze nie było czyszczenia", "Nog geen opruiming"],
    "overview.cleanupHistoryHint": ["La cronologia delle pulizie appare qui.", "O histórico de limpezas aparecerá aqui.", "清理記錄會顯示在這裡。", "Temizlik geçmişi burada görünür.", "Historia czyszczeń pojawi się tutaj.", "De opruimgeschiedenis verschijnt hier."],
    "overview.viewResults": ["Vedi i risultati", "Ver os resultados", "查看掃描結果", "Sonuçları gör", "Zobacz wyniki", "Bekijk resultaten"],
    "overview.localOnly": ["La scansione avviene interamente su questo Mac.", "A verificação roda inteiramente neste Mac.", "掃描全程在本機完成", "Tarama tamamen bu Mac’te yürür.", "Skanowanie odbywa się w całości na tym Macu.", "De scan draait volledig op deze Mac."],
    "overview.diskUsageDetail": ["%@ liberi, %@ totali", "%@ livres, %@ no total", "剩餘 %@，共 %@", "%@ boş, toplam %@", "%@ wolne, łącznie %@", "%@ vrij, %@ totaal"],
    "overview.lastCleanupTitle": ["Liberato dall’ultima pulizia", "Liberado na última limpeza", "上次清理釋放", "Son temizlikte kazanılan", "Odzyskano przy ostatnim czyszczeniu", "Vrijgemaakt bij de laatste opruiming"],
    "overview.lastCleanupMeta": ["%@, %d elementi, nel Cestino", "%@, %d itens, para a Lixeira", "%@，%d 項，全部移至垃圾桶", "%@, %d öğe, Çöp Sepeti’ne", "%@, %d elementów, do Kosza", "%@, %d items, naar de Prullenbak"],
    "overview.selectedSummary": ["%d selezionati, %@", "%d selecionados, %@", "已選 %d 項，%@", "%d seçildi, %@", "Wybrano: %d, %@", "%d geselecteerd, %@"],
    "overview.moreItems": ["Altri %d elementi minori, %@ in totale", "%d itens menores, %@ no total", "還有 %d 項較小內容，合計 %@", "%d küçük öğe daha, toplam %@", "Jeszcze %d mniejszych elementów, łącznie %@", "Nog %d kleinere items, totaal %@"],
    "overview.showAll": ["Mostra tutto", "Mostrar tudo", "展開全部", "Tümünü göster", "Pokaż wszystko", "Alles tonen"],
    "overview.historyLocal": ["La cronologia resta su questo Mac; nulla è sincronizzato o caricato.", "O histórico fica neste Mac; nada é sincronizado ou enviado.", "記錄僅保存在本機，不同步、不上傳。", "Geçmiş bu Mac’te kalır; hiçbir şey eşitlenmez veya yüklenmez.", "Historia zostaje na tym Macu; nic nie jest synchronizowane ani wysyłane.", "De geschiedenis blijft op deze Mac; niets wordt gesynchroniseerd of geüpload."],
    "overview.activityScan": ["Scansione terminata, %d elementi", "Verificação concluída, %d itens", "掃描完成，共 %d 項", "Tarama bitti, %d öğe", "Skanowanie zakończone, %d elementów", "Scan afgerond, %d items"],
    "overview.activityUninstall": ["Suggerimenti di disinstallazione, %d app non aperte da tempo", "Sugestão de desinstalação, %d apps não abertos recentemente", "解除安裝建議，%d 個應用程式長期未開啟", "Kaldırma önerisi, uzun süredir açılmayan %d uygulama", "Sugestie odinstalowania, %d aplikacji nieużywanych od dawna", "Verwijderadvies, %d apps al lang niet geopend"],
    "overview.activityStorage": ["Archiviazione analizzata, misurati %@", "Armazenamento analisado, %@ medidos", "儲存空間分析完成，已分析 %@", "Depolama analiz edildi, %@ ölçüldü", "Pamięć przeanalizowana, zmierzono %@", "Opslag geanalyseerd, %@ gemeten"],
    "scan.filter.all": ["Tutto", "Tudo", "全部", "Tümü", "Wszystko", "Alles"],
    "scan.filter.junk": ["Rifiuti", "Detritos", "垃圾", "Gereksizler", "Śmieci", "Rommel"],
    "scan.filter.large": ["Grandi", "Grandes", "大型檔案", "Büyükler", "Duże", "Grote"],
    "scan.filter.old": ["Datati", "Antigos", "舊檔案", "Eskiler", "Stare", "Oude"],
    "scan.filter.duplicates": ["Duplicati", "Duplicados", "重複", "Kopyalar", "Duplikaty", "Duplicaten"],
    "scan.rescan": ["Scansiona di nuovo", "Verificar novamente", "重新掃描", "Yeniden tara", "Skanuj ponownie", "Opnieuw scannen"],
    "scan.headerStatus": ["Risultati del %@ · %d elementi", "Resultados de %@ · %d itens", "結果來自 %@ · %d 個項目", "%@ tarihli sonuçlar · %d öğe", "Wyniki z %@ · %d elementów", "Resultaten van %@ · %d items"],
    "scan.results.safeGroup": ["Pulibile senza rischi", "Pode ser limpo", "可安全清理", "Güvenle temizlenebilir", "Bezpieczne do czyszczenia", "Veilig op te ruimen"],
    "scan.results.reviewGroup": ["Richiede la tua conferma", "Requer sua confirmação", "需要你確認", "Onayınızı gerektiriyor", "Wymaga potwierdzenia", "Vraagt om jouw bevestiging"],
    "scan.results.protectedGroup": ["Protetto", "Protegido", "受保護", "Korumalı", "Chronione", "Beschermd"],
    "scan.results.defaultSelected": ["Selezionato per impostazione predefinita", "Selecionado por padrão", "預設已選取", "Varsayılan olarak seçili", "Domyślnie zaznaczone", "Standaard geselecteerd"],
    "scan.results.reviewHint": ["Conferma ogni elemento prima di pulire", "Confirme cada item antes de limpar", "逐項確認後才可清理", "Temizlemeden önce her öğeyi onaylayın", "Potwierdź każdy element przed czyszczeniem", "Bevestig elk item vóór het opschonen"],
    "scan.results.cleanTitle": ["Questa pulizia", "Esta limpeza", "本次清理", "Bu temizlik", "To czyszczenie", "Deze opruiming"],
    "scan.results.cleanButton": ["Pulisci %d elementi", "Limpar %d itens", "清理 %d 項", "%d öğeyi temizle", "Wyczyść %d", "%d items opschonen"],
    "scan.results.trashHint": ["Va nel Cestino; recuperabile finché non lo svuoti.", "Vai para a Lixeira; recuperável até esvaziá-la.", "移入垃圾桶，清空垃圾桶前可還原。", "Çöp Sepeti’ne taşınır; boşaltana kadar geri alınabilir.", "Trafia do Kosza; do przywrócenia do jego opróżnienia.", "Gaat naar de Prullenbak; terug te zetten totdat je die leegt."],
    "scan.results.protectedHint": ["File di sistema e posizioni protette sono saltati automaticamente", "Arquivos do sistema e localizações protegidas são ignorados automaticamente", "自動略過系統檔案與受保護路徑", "Sistem dosyaları ve korumalı konumlar otomatik atlanır", "Pliki systemowe i chronione lokalizacje są pomijane automatycznie", "Systeembestanden en beschermde locaties worden automatisch overgeslagen"],
    "scan.results.reportHint": ["Ripristina dal Cestino o esporta un rapporto di pulizia.", "Restaure da Lixeira ou exporte um relatório de limpeza.", "可在垃圾桶還原，或輸出清理報告。", "Çöp Sepeti’nden geri alın veya temizlik raporunu dışa aktarın.", "Przywróć z Kosza lub wyeksportuj raport czyszczenia.", "Zet terug uit de Prullenbak of exporteer een opschoningsrapport."],
    "scan.results.sortSize": ["Per dimensione", "Por tamanho", "按大小", "Boyuta göre", "Według rozmiaru", "Op grootte"],
    "scan.results.sortName": ["Per nome", "Por nome", "按名稱", "Ada göre", "Według nazwy", "Op naam"],
    "scan.results.sortModified": ["Per data di modifica", "Por data de modificação", "按修改時間", "Değişiklik tarihine göre", "Według daty modyfikacji", "Op wijzigingsdatum"],
    "scan.results.categoryTotals": ["Per categoria: %@", "Por categoria: %@", "按類別：%@", "Kategoriye göre: %@", "Według kategorii: %@", "Per categorie: %@"],
    "scan.running.status": ["Scansione, passo %d di %d", "Verificando, etapa %d de %d", "掃描進行中，第 %d 步，共 %d 步", "Taranıyor, adım %d / %d", "Skanowanie, krok %d z %d", "Scannen, stap %d van %d"],
    "scan.running.step": ["Passo %d di %d", "Etapa %d de %d", "第 %d 步，共 %d 步", "Adım %d / %d", "Krok %d z %d", "Stap %d van %d"],
    "scan.running.target": ["Obiettivo corrente", "Objetivo atual", "本輪目標", "Geçerli hedef", "Bieżący cel", "Huidige doel"],
    "scan.running.walked": ["%@ file attraversati", "%@ arquivos percorridos", "已遍歷 %@ 個檔案", "%@ dosya gezildi", "Przejrzano %@ plików", "%@ bestanden doorlopen"],
    "scan.running.found": ["%@ trovati", "%@ encontrados", "已發現 %@", "%@ bulundu", "Znaleziono %@", "%@ gevonden"],
    "scan.running.elapsed": ["Tempo trascorso", "Tempo decorrido", "已用時", "Geçen süre", "Czas trwania", "Verstreken tijd"],
    "scan.running.phase": ["Fase corrente", "Fase atual", "目前階段", "Geçerli aşama", "Bieżący etap", "Huidige fase"],
    "scan.running.readOnly": ["Legge solo nomi, dimensioni e date di modifica. Non apre mai i file e non invia dati.", "Lê apenas nomes, tamanhos e datas de modificação. Não abre arquivos nem envia dados.", "只讀取檔名、大小與修改時間，不開啟內容、不上傳任何資料", "Yalnızca ad, boyut ve değişiklik tarihi okur. Dosyaları açmaz, veri göndermez.", "Czyta tylko nazwy, rozmiary i daty modyfikacji. Nie otwiera plików ani niczego nie wysyła.", "Leest alleen namen, groottes en wijzigingsdata. Opent nooit bestanden en verstuurt niets."],
    "scan.running.categories": ["Trovato per categoria", "Encontrado por categoria", "分類發現", "Kategoriye göre bulunanlar", "Znalezione według kategorii", "Gevonden per categorie"],
    "scan.running.categoryCount": ["%d categorie", "%d categorias", "%d 個類別", "%d kategori", "%d kategorie", "%d categorieën"],
    "scan.running.waiting": ["In attesa", "Em espera", "等待中", "Bekliyor", "Oczekiwanie", "Wachten"],
    "scan.running.finding": ["Trovando", "Encontrando", "發現中", "Bulunuyor", "Wyszukiwanie", "Vindt"],

    "apps.status": ["Installate %d, %d non aperte da 6 mesi", "%d instalados, %d sem abrir há 6 meses", "已安裝 %d 個，%d 個超過 6 個月未開啟", "%d yüklü, %d altı 6 aydır açılmadı", "Zainstalowane: %d, %d nieotwierane od 6 miesięcy", "%d geïnstalleerd, %d niet geopend in 6 maanden"],
    "apps.listTitle": ["Applicazioni", "Aplicativos", "應用程式列表", "Uygulamalar", "Aplikacje", "Apps"],
    "apps.sortSummary": ["Ordinate per dimensione, %@ in totale", "Ordenados por tamanho, %@ no total", "按體積排序，共 %@", "Boyuta göre sıralandı, toplam %@", "Sortowane według rozmiaru, łącznie %@", "Op grootte gesorteerd, totaal %@"],
    "apps.reclaimable": ["Puoi liberare", "Pode ser liberado", "本次可釋放", "Kazanılabilir", "Można odzyskać", "Vrij te maken"],
    "apps.appAndRelated": ["App %@, file correlati %@", "App %@, arquivos relacionados %@", "應用程式本體 %@，相關檔案 %@", "Uygulama %@, ilgili dosyalar %@", "Aplikacja %@, pliki powiązane %@", "App %@, gerelateerde bestanden %@"],
    "apps.relatedWillRemove": ["File correlati da rimuovere", "Arquivos relacionados a remover", "將一併刪除的相關檔案", "Kaldırılacak ilgili dosyalar", "Pliki powiązane do usunięcia", "Gerelateerde bestanden om te verwijderen"],
    "apps.uninstallAndClean": ["Disinstalla e pulisci %@", "Desinstalar e limpar %@", "解除安裝並清理 %@", "Kaldır ve %@ temizle", "Odinstaluj i wyczyść %@", "Verwijderen en %@ opschonen"],
    "apps.restoreHint": ["Recuperabile dal Cestino finché non lo svuoti", "Recuperável da Lixeira até esvaziá-la", "清空垃圾桶前可還原", "Çöp Sepeti’ni boşaltana kadar geri alınabilir", "Do przywrócenia z Kosza do jego opróżnienia", "Terug te zetten uit de Prullenbak totdat je die leegt"],
    "apps.footer": ["Mostra le app oltre 200 MB, %d in totale", "Mostra apps acima de 200 MB, %d no total", "僅顯示超過 200 MB 的應用程式，共 %d 個", "Yalnızca 200 MB üzeri uygulamalar, toplam %d", "Pokazano aplikacje ponad 200 MB, łącznie %d", "Toont apps boven 200 MB, %d totaal"],
    "apps.lastOpened": ["Ultima apertura %@", "Última abertura %@", "上次開啟於%@", "Son açılış %@", "Ostatnio otwarto %@", "Laatst geopend %@"],
    "apps.neverOpened": ["Mai aperta", "Nunca aberto", "從未開啟", "Hiç açılmadı", "Nigdy nie otwierano", "Nooit geopend"],

    "storage.startTitle": ["Scopri cosa occupa il disco", "Veja o que ocupa o disco", "看看磁碟被什麼佔用", "Diski neyin kapladığına bakın", "Zobacz, co zajmuje dysk", "Zie wat de schijf bezet houdt"],
    "storage.status": ["%@, %@ usati su %@", "%@, %@ usados de %@", "%@，已用 %@，共 %@", "%@, %@ / %@ kullanıldı", "%@, zajęte %@ z %@", "%@, %@ gebruikt van %@"],
    "storage.spaceDistribution": ["Distribuzione dello spazio", "Distribuição do espaço", "空間分佈", "Alan dağılımı", "Rozkład miejsca", "Ruimteverdeling"],
    "storage.categoryDetail": ["Dettaglio per categoria", "Detalhamento por categoria", "分類明細", "Kategori dökümü", "Szczegóły według kategorii", "Uitsplitsing per categorie"],
    "storage.usageShare": ["Utilizzo", "Uso", "佔用佔比", "Kullanım", "Wykorzystanie", "Gebruik"],
    "storage.availableSpace": ["Disponibile", "Disponível", "可用空間", "Kullanılabilir", "Dostępne", "Beschikbaar"],
    "storage.localNote": ["Misurato su questo Mac. Nulla viene caricato o inviato online.", "Medido neste Mac. Nada é enviado para a rede.", "資料來自本機分析，不上傳、不連網。", "Bu Mac’te ölçüldü. Hiçbir şey yüklenmez veya gönderilmez.", "Zmierzono na tym Macu. Nic nie jest wysyłane ani umieszczane w sieci.", "Gemeten op deze Mac. Niets wordt geüpload of online verstuurd."],
    "storage.suggestionTitle": ["Suggerimento", "Sugestão", "建議", "Öneri", "Sugestia", "Suggestie"],
    "storage.cleanableHeading": ["%@ si possono pulire", "%@ podem ser limpos", "%@ 可清理", "%@ temizlenebilir", "%@ można wyczyścić", "%@ kan worden opgeruimd"],
    "storage.suggestionDetail": ["Inizia da cache e installer datati, poi scansiona di nuovo per confermare.", "Comece por caches e instaladores antigos e verifique novamente para confirmar.", "先處理快取和舊安裝程式，再掃描一次確認。", "Önbellek ve eski yükleyicilerle başlayın, sonra doğrulamak için yeniden tarayın.", "Zacznij od pamięci podręcznych i starych instalatorów, potem skanuj ponownie dla potwierdzenia.", "Begin met caches en oude installatieprogramma’s en scan daarna opnieuw ter bevestiging."],
    "storage.goClean": ["Vai alla pulizia", "Ir para a limpeza", "去清理", "Temizlemeye git", "Przejdź do czyszczenia", "Ga opschonen"],

    "settings.headerStatus": ["Impostazioni, Sift %@", "Ajustes, Sift %@", "設定，Sift %@", "Ayarlar, Sift %@", "Ustawienia, Sift %@", "Instellingen, Sift %@"],
    "language.search": ["Cerca lingue", "Pesquisar idiomas", "搜尋語言", "Dil ara", "Szukaj języków", "Talen zoeken"],
    "language.noResults": ["Nessuna lingua corrispondente", "Nenhum idioma correspondente", "沒有符合的語言", "Eşleşen dil yok", "Brak pasujących języków", "Geen overeenkomende taal"],

    # --- Trash and snapshots ---
    "trash.empty.action": ["Svuota il cestino", "Esvaziar o Lixo", "清空垃圾桶", "Çöp Sepetini Boşalt", "Opróżnij kosz", "Prullenmand leegmaken"],
    "trash.empty.message": ["Elimina definitivamente %@. L’operazione non è reversibile.", "Remove %@ permanentemente. Não é possível desfazer.", "將永久刪除 %@，無法復原。", "%@ kalıcı olarak silinir. Bu işlem geri alınamaz.", "%@ zostanie trwale usunięte. Tej operacji nie można cofnąć.", "%@ wordt definitief verwijderd. Dit kan niet ongedaan worden gemaakt."],
    "diagnostics.snapshots.openTimeMachine": ["Apri Time Machine", "Abrir o Time Machine", "開啟「時光機」", "Time Machine’i Aç", "Otwórz Time Machine", "Time Machine openen"],

    # --- Coverage diagnostics ---
    "diagnostics.coverage.title": ["Copertura delle regole", "Cobertura das regras", "規則覆蓋", "Kural kapsamı", "Pokrycie reguł", "Regeldekking"],
    "diagnostics.coverage.detail": ["Esegue una scansione con la tabella di regole corrente e mostra cosa ha trovato ogni regola e quali cartelle grandi nessuna regola raggiunge.", "Executa uma verificação com a tabela de regras atual e mostra o que cada regra encontrou e quais pastas grandes nenhuma regra alcança.", "用目前規則表執行一次掃描，統計每條規則命中的項目與大小，並列出沒有任何規則涵蓋的大型資料夾。", "Geçerli kural tablosuyla bir tarama yapar; her kuralın ne bulduğunu ve hangi büyük klasörlere hiçbir kuralın ulaşmadığını gösterir.", "Uruchamia skanowanie z bieżącą tabelą reguł i pokazuje, co znalazła każda reguła oraz których dużych folderów żadna nie obejmuje.", "Voert één scan uit met de huidige regeltabel en toont wat elke regel vond en welke grote mappen geen regel bereikt."],
    "diagnostics.coverage.run": ["Esegui controllo", "Executar auditoria", "執行覆蓋診斷", "Kapsamı denetle", "Sprawdź pokrycie", "Dekking controleren"],
    "diagnostics.coverage.idle": ["Regole senza risultati: %@", "Regras sem resultados: %@", "沒有命中的規則：%@", "Sonuç bulamayan kurallar: %@", "Reguły bez wyników: %@", "Regels zonder treffer: %@"],
    "diagnostics.coverage.uncovered": ["Cartelle grandi non coperte", "Pastas grandes sem cobertura", "沒有規則涵蓋的大型資料夾", "Hiçbir kuralın ulaşmadığı büyük klasörler", "Duże foldery bez pokrycia", "Grote mappen zonder regel"],
    "diagnostics.coverage.rule": ["Regola", "Regra", "規則", "Kural", "Reguła", "Regel"],
    "diagnostics.coverage.synthesized": ["Scansione", "Varredura", "內建掃描", "Tarama", "Skan", "Scan"],
    "diagnostics.coverage.synthesizedNote": ["Le righe contrassegnate «Scansione» provengono dal codice di scansione — residui, soglie di dimensione ed età —, non dal file di regole. Nessuna regola può esprimerle e una bozza di regola non si applica.", "As linhas marcadas «Varredura» vêm do código de varredura — resíduos, limites de tamanho e idade —, não do arquivo de regras. Nenhuma regra pode expressá-las e um rascunho de regra não se aplica.", "標為「內建掃描」的列來自掃描程式碼（殘留、大小與存留時間門檻），不來自規則檔：規則無法表達它們，規則草稿也不適用。", "«Tarama» olarak işaretlenen satırlar kural dosyasından değil tarama kodundan gelir — kalıntılar, boyut ve yaş eşikleri. Hiçbir kural bunları ifade edemez ve kural taslağı bunlara uygulanmaz.", "Wiersze oznaczone „Skan” pochodzą z kodu skanowania — pozostałości, progi rozmiaru i wieku — a nie z pliku reguł. Żadna reguła nie może ich wyrazić i szkic reguły ich nie dotyczy.", "Rijen met «Scan» komen uit de scancode — resten, grootte- en leeftijdsdrempels —, niet uit het regelbestand. Geen regel kan ze uitdrukken en een regelconcept is er niet op van toepassing."],

    # --- Rule drafts ---
    "diagnostics.coverage.draftTitle": ["Bozza di regola", "Rascunho de regra", "規則草稿", "Kural taslağı", "Szkic reguły", "Regelconcept"],
    "diagnostics.coverage.draftDetail": ["Aggiungi questo al tuo file di regole, poi attiva «Usa un file di regole personalizzato» nelle Impostazioni. Fino ad allora non viene pulito nulla.", "Adicione isto ao seu próprio arquivo de regras e ative «Usar um arquivo de regras próprio» nos Ajustes. Até então nada é limpo.", "把這段加入你自己的規則檔，然後在設定中開啟「使用自訂規則檔」。在此之前不會清理任何東西。", "Bunu kendi kural dosyanıza ekleyip Ayarlar’da “Özel kural dosyası kullan” seçeneğini açın. O zamana kadar hiçbir şey temizlenmez.", "Dodaj to do własnego pliku reguł i włącz „Używaj własnego pliku reguł” w Ustawieniach. Do tego czasu nic nie jest usuwane.", "Voeg dit toe aan je eigen regelbestand en zet ‘Eigen regelbestand gebruiken’ aan in Instellingen. Tot die tijd wordt er niets opgeruimd."],
    "diagnostics.coverage.draftCopy": ["Copia", "Copiar", "複製", "Kopyala", "Kopiuj", "Kopiëren"],
    "diagnostics.coverage.draftCannot": ["Questa cartella non può essere coperta da una regola: %@", "Esta pasta não pode ser coberta por uma regra: %@", "這個資料夾不能由規則涵蓋：%@", "Bu klasör bir kuralla kapsanamaz: %@", "Ten folder nie może być objęty regułą: %@", "Deze map kan niet door een regel worden gedekt: %@"],

    # --- Residue categories ---
    "cleanup.category.groupContainerResidue": ["Residui di contenitori condivisi", "Resíduos de contêineres compartilhados", "共享容器殘留", "Paylaşılan kapsayıcı artıkları", "Pozostałości wspólnych kontenerów", "Resten van gedeelde containers"],

    # --- Residue ownership ---
    "uninstall.sharedContainer": ["Condiviso anche con: %@", "Também compartilhado com: %@", "也被這些應用程式共用：%@", "Şunlarla da paylaşılıyor: %@", "Współdzielone także z: %@", "Ook gedeeld met: %@"],
    "scan.results.ownerAction": ["Di quale app è?", "De qual app é?", "是哪個應用程式的？", "Hangi uygulamaya ait?", "Do jakiej aplikacji należy?", "Van welke app is dit?"],
    "scan.results.ownerMissing": ["Nessuna applicazione installata per %@. L’identificatore è stato copiato.", "Nenhuma aplicação instalada para %@. O identificador foi copiado.", "沒有為 %@ 安裝應用程式，已複製其識別碼。", "%@ için yüklü bir uygulama yok. Tanımlayıcı kopyalandı.", "Brak zainstalowanej aplikacji dla %@. Identyfikator został skopiowany.", "Geen app geïnstalleerd voor %@. De identifier is gekopieerd."],

    # --- Cleanup confirmation ----------------------------------------------------
    "cleanup.confirm.titleCount": [
        "Spostare %d elementi nel Cestino?",
        "Mover %d itens para a Lixeira?",
        "要將 %d 個項目移入垃圾桶嗎？",
        "%d öğe Çöp Sepeti’ne taşınsın mı?",
        "Przenieść %d elementów do Kosza?",
        "%d items naar de Prullenbak verplaatsen?",
    ],
    "cleanup.confirm.moveAction": ["Sposta nel Cestino", "Mover para a Lixeira", "移入垃圾桶", "Çöp Sepeti’ne taşı", "Przenieś do Kosza", "Naar de Prullenbak"],
    "cleanup.confirm.showItems": [
        "Controlla ogni elemento (%d)",
        "Revisar cada item (%d)",
        "逐項檢視（%d 項）",
        "Her öğeyi gözden geçir (%d)",
        "Przejrzyj każdy element (%d)",
        "Elk item bekijken (%d)",
    ],
    "cleanup.confirm.hideItems": ["Nascondi l’elenco", "Ocultar a lista", "隱藏清單", "Listeyi gizle", "Ukryj listę", "Lijst verbergen"],
    "cleanup.confirm.locations": ["Posizioni", "Locais", "來源位置", "Konumlar", "Lokalizacje", "Locaties"],
    "cleanup.confirm.protectedCount": [
        "%d protetti, non spostati",
        "%d protegidos, não movidos",
        "%d 項受保護，將保持不動",
        "%d öğe korumalı, taşınmadı",
        "%d chronionych, nie przeniesiono",
        "%d beschermd, niet verplaatst",
    ],
    "cleanup.confirm.missingCount": [
        "%d già spariti, saltati",
        "%d já não existem, ignorados",
        "%d 項已不存在，已略過",
        "%d öğe artık yok, atlandı",
        "%d już nie istnieje, pominięto",
        "%d al verdwenen, overgeslagen",
    ],
    "cleanup.confirm.reviewCount": ["%d da verificare", "%d precisam da sua revisão", "%d 項待你確認", "%d öğe onayınızı bekliyor", "%d wymaga sprawdzenia", "%d vragen om jouw bevestiging"],
    "cleanup.confirm.whyRecoverable": [
        "Perché è recuperabile",
        "Por que isso é recuperável",
        "為什麼可以還原",
        "Neden geri alınabilir",
        "Dlaczego można to przywrócić",
        "Waarom dit terug te zetten is",
    ],

    # --- Cleanup progress and result ---------------------------------------------
    "cleanup.preparing.title": ["Verifica degli elementi", "Verificando os itens", "正在核對項目", "Öğeler kontrol ediliyor", "Sprawdzanie elementów", "Items controleren"],
    "cleanup.executing.title": ["Spostamento nel Cestino", "Movendo para a Lixeira", "正在移至垃圾桶", "Çöp Sepeti’ne taşınıyor", "Przenoszenie do Kosza", "Naar de Prullenbak verplaatsen"],
    "cleanup.executing.progress": ["%d di %d", "%d de %d", "%d / %d", "%d / %d", "%d z %d", "%d van %d"],
    "cleanup.result.reclaimAfterEmpty": [
        "Lo spazio disponibile aumenta di %@ quando svuoti il Cestino",
        "O espaço disponível aumenta %@ quando você esvaziar a Lixeira",
        "清空垃圾桶後，可用空間會增加 %@",
        "Çöp Sepeti’ni boşalttığınızda kullanılabilir alan %@ artar",
        "Po opróżnieniu Kosza wolne miejsce wzrośnie o %@",
        "De vrije ruimte groeit met %@ zodra je de Prullenbak leegt",
    ],
    "cleanup.result.retryCount": ["Riprova %d", "Tentar novamente %d", "重試 %d 項", "%d öğeyi yeniden dene", "Ponów próbę: %d", "Opnieuw proberen: %d"],
    "cleanup.result.undoAction": ["Annulla questa pulizia", "Desfazer esta limpeza", "還原這次清理", "Bu temizliği geri al", "Cofnij to czyszczenie", "Deze opruiming ongedaan maken"],
    "cleanup.result.undoUnavailable": [
        "Impossibile annullare: il Cestino è stato svuotato o l’elemento è su un altro disco",
        "Não é possível desfazer: a Lixeira foi esvaziada ou o item está em outro disco",
        "無法復原：垃圾桶已清空，或項目位於其他磁碟",
        "Geri alınamaz: Çöp Sepeti boşaltıldı veya öğe başka bir diskte",
        "Nie można cofnąć: Kosz został opróżniony lub element jest na innym dysku",
        "Ongedaan maken kan niet: de Prullenbak is geleegd of het item staat op een andere schijf",
    ],
    "cleanup.result.stopped": [
        "Interrotto dopo %d elementi",
        "Interrompido após %d itens",
        "已停止，共處理 %d 項",
        "%d öğeden sonra durduruldu",
        "Zatrzymano po %d elementach",
        "Gestopt na %d items",
    ],

    # --- Scan state --------------------------------------------------------------
    "scan.stopped.title": ["Scansione interrotta", "Verificação interrompida", "掃描停止", "Tarama durduruldu", "Skanowanie zatrzymane", "Scan gestopt"],
    "scan.stopped.detail": [
        "Prima di interrompere sono stati trovati %d elementi (%@). Puoi comunque pulirli.",
        "%d itens (%@) foram encontrados antes de você parar. Você ainda pode limpá-los.",
        "掃描停止前找到 %d 個項目（%@），仍可清理。",
        "Durdurmadan önce %d öğe (%@) bulundu. Bunları yine de temizleyebilirsiniz.",
        "Przed zatrzymaniem znaleziono %d elementów (%@). Nadal możesz je wyczyścić.",
        "Er zijn %d items (%@) gevonden voordat je stopte. Je kunt ze nog steeds opschonen.",
    ],
    "scan.stopping": ["Interruzione…", "Parando…", "正在停止掃描…", "Durduruluyor…", "Zatrzymywanie…", "Stoppen…"],
    "scan.hiddenSelected": [
        "%d elementi selezionati non sono mostrati qui",
        "%d itens selecionados não aparecem aqui",
        "有 %d 項已選取，但未顯示在此清單",
        "Seçili %d öğe burada gösterilmiyor",
        "%d zaznaczonych elementów nie jest tu pokazanych",
        "%d geselecteerde items worden hier niet getoond",
    ],
    "scan.nothingFoundScope": ["Niente in questo ambito", "Nada neste escopo", "此範圍沒有項目", "Bu kapsamda hiçbir şey yok", "Nic w tym zakresie", "Niets in dit bereik"],

    # --- File cleanup empty states -----------------------------------------------
    "files.noDuplicatesDetail": [
        "Nessun file duplicato nelle cartelle scansionate da Sift.",
        "Nenhum arquivo duplicado nas pastas verificadas pelo Sift.",
        "Sift 掃描的資料夾中沒有重複檔案。",
        "Sift’in taradığı klasörlerde kopya dosya yok.",
        "Brak duplikatów w folderach przeskanowanych przez Sift.",
        "Geen dubbele bestanden in de mappen die Sift heeft gescand.",
    ],

    # --- Full Disk Access and scan scope -----------------------------------------
    "permission.askTitle": [
        "Lasciare che Sift legga qualcosa in più?",
        "Deixar o Sift ler um pouco mais?",
        "要讓 Sift 讀取更多位置嗎？",
        "Sift biraz daha okusun mu?",
        "Pozwolić Siftowi czytać nieco więcej?",
        "Sift iets meer laten lezen?",
    ],
    "permission.whyTitle": [
        "Perché l’Accesso completo al disco",
        "Por que o Acesso Total ao Disco",
        "為什麼需要「完全磁碟存取權限」",
        "Neden Tam Disk Erişimi",
        "Dlaczego pełny dostęp do dysku",
        "Waarom Volledige Schijftoegang",
    ],
    "permission.whyBody": [
        "Copre i log di sistema e le cartelle di supporto delle app, che macOS protegge. Tutto il resto funziona anche senza.",
        "Ele cobre logs do sistema e as pastas de suporte dos apps, que o macOS protege. Todo o resto funciona sem isso.",
        "它涵蓋系統記錄檔與應用程式支援資料夾，這些位置受 macOS 保護。其他功能不需要這項權限。",
        "Sistem günlüklerini ve macOS’un koruduğu uygulama destek klasörlerini kapsar. Diğer her şey bu izin olmadan çalışır.",
        "Obejmuje dzienniki systemowe i foldery wsparcia aplikacji, które macOS chroni. Wszystko inne działa bez niego.",
        "Het dekt systeemlogbestanden en app-ondersteuningsmappen, die macOS beschermt. Al het andere werkt zonder.",
    ],
    "permission.whyRevoke": [
        "Puoi disattivarlo quando vuoi in Impostazioni di Sistema → Privacy e sicurezza.",
        "Você pode desativá-lo a qualquer momento em Ajustes do Sistema → Privacidade e Segurança.",
        "可隨時在系統設定 → 隱私權與安全性中關閉。",
        "Sistem Ayarları → Gizlilik ve Güvenlik bölümünden istediğiniz zaman kapatabilirsiniz.",
        "Możesz to wyłączyć w dowolnej chwili w Ustawieniach systemowych → Prywatność i bezpieczeństwo.",
        "Je kunt het altijd uitzetten in Systeeminstellingen → Privacy en beveiliging.",
    ],
    "permission.openedSettings": [
        "Impostazioni di Sistema è aperto. Torna qui e avvia di nuovo la scansione.",
        "Os Ajustes do Sistema estão abertos. Volte e verifique novamente.",
        "已打開系統設定，回來後請重新掃描。",
        "Sistem Ayarları açık. Buraya dönüp yeniden tarayın.",
        "Ustawienia systemowe są otwarte. Wróć i uruchom skanowanie ponownie.",
        "Systeeminstellingen staat open. Kom terug en scan opnieuw.",
    ],
    "permission.protectedTitle": ["Protetti da Sift", "Protegidos pelo Sift", "Sift 保護的項目", "Sift tarafından korunuyor", "Chronione przez Sift", "Beschermd door Sift"],
    "permission.systemProtectedTitle": ["Posizioni chiuse da macOS", "Locais fechados pelo macOS", "系統保護的位置", "macOS'un kapalı tuttuğu konumlar", "Lokalizacje zamknięte przez macOS", "Locaties die macOS gesloten houdt"],
    "permission.restartHint": ["Se l'accesso completo al disco è già attivo, chiudi Sift e riaprilo: macOS applica l'autorizzazione all'avvio dell'app.", "Se o Acesso Total ao Disco já está ativado, encerre o Sift e abra-o de novo: o macOS aplica a permissão quando o app inicia.", "如果已經開啟完全磁碟存取權限，請結束 Sift 後重新開啟；macOS 只在應用程式啟動時套用該授權。", "Tam Disk Erişimi zaten açıksa Sift'i kapatıp yeniden açın — macOS izni uygulama başlatılırken uygular.", "Jeśli Pełny dostęp do dysku jest już włączony, zamknij Sift i otwórz go ponownie — macOS stosuje zgodę przy starcie aplikacji.", "Staat Volledige schijftoegang al aan, sluit Sift dan af en open het opnieuw — macOS past de toestemming toe wanneer een app start."],
    "scan.skippedReason.systemRestricted": ["Questa posizione appartiene a macOS o a un altro utente, quindi Sift non può leggerla.", "Este local pertence ao macOS ou a outro usuário, então o Sift não consegue lê-lo.", "這個位置屬於 macOS 或其他使用者，Sift 無法讀取。", "Bu konum macOS'a veya başka bir kullanıcıya ait, bu yüzden Sift burayı okuyamıyor.", "Ta lokalizacja należy do macOS lub innego użytkownika, więc Sift nie może jej odczytać.", "Deze locatie is eigendom van macOS of een andere gebruiker, dus Sift kan hem niet lezen."],
    "scan.firstRun.scope": [
        "Sift legge cache, log e installer in queste posizioni:",
        "O Sift lê caches, logs e instaladores nestes locais:",
        "Sift 會讀取下列位置的快取、記錄檔與安裝程式：",
        "Sift bu konumlardaki önbellekleri, günlükleri ve yükleyicileri okur:",
        "Sift czyta pamięci podręczne, dzienniki i instalatory w tych lokalizacjach:",
        "Sift leest caches, logbestanden en installatieprogramma’s op deze locaties:",
    ],
    "scan.scopeNote": [
        "Legge solo nomi, dimensioni e date · la copertura completa richiede l’Accesso completo al disco",
        "Lê apenas nomes, tamanhos e datas · a cobertura completa exige o Acesso Total ao Disco",
        "只讀取名稱、大小與日期 · 完整涵蓋需「完全磁碟存取權限」",
        "Yalnızca adları, boyutları ve tarihleri okur · tam kapsam için Tam Disk Erişimi gerekir",
        "Czyta tylko nazwy, rozmiary i daty · pełne pokrycie wymaga pełnego dostępu do dysku",
        "Leest alleen namen, groottes en datums · volledige dekking vereist Volledige Schijftoegang",
    ],

    # --- Purchase, settings and navigation ---------------------------------------
    "purchase.activate": ["Attiva una chiave di licenza", "Ativar uma chave de licença", "啟用授權碼", "Lisans anahtarını etkinleştir", "Aktywuj klucz licencji", "Licentiesleutel activeren"],
    "purchase.openStore": ["Acquista sul sito", "Comprar no site", "在官網購買", "Web sitesinden satın al", "Kup na stronie", "Kopen op de website"],
    "purchase.unavailable": [
        "L’acquisto in-app non è disponibile in questa versione.",
        "A compra no app não está disponível nesta versão.",
        "這個版本不提供 App 內購買。",
        "Bu sürümde uygulama içi satın alma kullanılamıyor.",
        "W tej wersji zakup w aplikacji jest niedostępny.",
        "In-app aankopen zijn niet beschikbaar in deze versie.",
    ],
    "settings.showConfirmList": [
        "Mostra l’elenco degli elementi prima di pulire",
        "Mostrar a lista de itens antes de limpar",
        "清理前顯示項目清單",
        "Temizlemeden önce öğe listesini göster",
        "Pokaż listę elementów przed czyszczeniem",
        "Toon de itemlijst vóór het opschonen",
    ],
    "settings.showConfirmListWarning": [
        "Disattivandola togli l’ultimo controllo. Gli elementi vanno comunque nel Cestino, ma non vedrai cosa viene spostato.",
        "Desativar isso remove a última checagem. Os itens ainda vão para a Lixeira, mas você não verá o que é movido.",
        "關閉後就少了最後一道把關。項目仍會移入垃圾桶，但你不會看到移動了什麼。",
        "Bunu kapatmak son denetimi ortadan kaldırır. Öğeler yine Çöp Sepeti’ne gider, ama neyin taşındığını görmezsiniz.",
        "Wyłączenie tego usuwa ostatnią kontrolę. Elementy nadal trafiają do Kosza, ale nie zobaczysz, co jest przenoszone.",
        "Dit uitzetten haalt de laatste controle weg. Items gaan nog steeds naar de Prullenbak, maar je ziet niet wat er verplaatst wordt.",
    ],
    "settings.includeHidden": [
        "Includi i file nascosti nelle scansioni",
        "Incluir arquivos ocultos nas verificações",
        "掃描時包含隱藏檔案",
        "Taramalara gizli dosyaları dahil et",
        "Uwzględniaj ukryte pliki w skanowaniach",
        "Verborgen bestanden meenemen in scans",
    ],
    "trash.emptyConfirmAction": ["Elimina definitivamente", "Excluir permanentemente", "永久刪除", "Kalıcı olarak sil", "Usuń trwale", "Definitief verwijderen"],
    "common.copyReason": ["Copia il motivo", "Copiar o motivo", "拷貝原因", "Nedeni kopyala", "Kopiuj przyczynę", "Reden kopiëren"],
    "common.stop": ["Interrompi", "Parar", "中止", "Durdur", "Zatrzymaj", "Stoppen"],
    "cleanup.busyNotice": ["Un'altra operazione è ancora in corso. Riprova tra un momento.", "Outra operação ainda está em andamento. Tente novamente em instantes.", "另一個操作仍在進行，請稍後再試。", "Başka bir işlem sürüyor. Biraz sonra tekrar deneyin.", "Inna operacja wciąż trwa. Spróbuj ponownie za chwilę.", "Er loopt nog een andere bewerking. Probeer het zo opnieuw."],
    "cleanup.nothingToDo": ["Al momento non è possibile spostare nulla della selezione.", "Nada da seleção pode ser movido agora.", "目前選取的內容暫時無法移動。", "Şu anda seçimdeki hiçbir öğe taşınamıyor.", "Nie można teraz przenieść niczego z zaznaczenia.", "Er kan nu niets uit deze selectie worden verplaatst."],
    "scan.partialBudget": ["La scansione si è fermata prima per restare reattiva: i risultati sono parziali.", "A verificação terminou antes para manter a fluidez: os resultados são parciais.", "掃描為保持流暢而提前結束，結果不完整。", "Uygulama akıcı kalsın diye tarama erken bitti: sonuçlar kısmi.", "Skanowanie zakończyło się wcześniej, aby zachować płynność — wyniki są częściowe.", "De scan stopte eerder om vlot te blijven — de resultaten zijn gedeeltelijk."],
    "settings.ignoreEmpty": ["Nessuna cartella esclusa.", "Nenhuma pasta ignorada ainda.", "還沒有忽略任何資料夾。", "Henüz yok sayılan klasör yok.", "Nie pominięto jeszcze żadnego folderu.", "Nog geen map uitgesloten."],
    "settings.addFolder": ["Aggiungi una cartella", "Adicionar uma pasta", "加入資料夾", "Klasör ekle", "Dodaj folder", "Map toevoegen"],
    "settings.keepHistory": ["Cronologia da conservare", "Histórico a manter", "保留的掃描紀錄數", "Saklanacak tarama sayısı", "Liczba skanów do zachowania", "Aantal scans om te bewaren"],
    "settings.launchAtLogin": ["Apri Sift all'accesso", "Abrir o Sift ao iniciar sessão", "登入時開啟 Sift", "Girişte Sift'i aç", "Otwieraj Sift przy logowaniu", "Sift openen bij inloggen"],
    "common.today": ["Oggi", "Hoje", "今天", "Bugün", "Dzisiaj", "Vandaag"],
    "common.yesterday": ["Ieri", "Ontem", "昨天", "Dün", "Wczoraj", "Gisteren"],
    "common.daysAgo": ["%d giorni fa", "Há %d dias", "%d 天前", "%d gün önce", "%d dni temu", "%d dagen geleden"],
    "settings.textSize": ["Dimensione del testo", "Tamanho do texto", "介面字級", "Yazı boyutu", "Rozmiar tekstu", "Tekstgrootte"],
    "settings.textSizeSmall": ["Piccolo", "Pequeno", "小", "Küçük", "Mały", "Klein"],
    "settings.textSizeDefault": ["Predefinito", "Padrão", "預設", "Varsayılan", "Domyślny", "Standaard"],
    "settings.textSizeLarge": ["Grande", "Grande", "大", "Büyük", "Duży", "Groot"],
    "scan.firstRun.review": ["Prima pulizia: apri l'elenco prima di confermare.", "Primeira limpeza: abra a lista antes de confirmar.", "第一次清理：確認前建議展開清單看一眼。", "İlk temizlik: onaylamadan önce listeyi açın.", "Pierwsze czyszczenie: rozwiń listę przed potwierdzeniem.", "Eerste opschoning: open de lijst voordat je bevestigt."],
}

# The two tables are one catalogue: the v1 columns stay first and the expansion
# follows. Both must cover exactly the same keys; the check below fails the
# generation when they drift apart, so a key cannot gain a v1 translation
# without the six expansion ones and vice versa.
LANGUAGES = LANGUAGES + EXPANSION_LANGUAGES

_missing = [key for key in STRINGS if key not in STRINGS_EXPANSION]
_extra = [key for key in STRINGS_EXPANSION if key not in STRINGS]
if _missing or _extra:
    raise SystemExit(
        f"the expansion table is out of step with the v1 table: "
        f"{len(_missing)} missing (first: {_missing[:3]}), "
        f"{len(_extra)} extra (first: {_extra[:3]})"
    )
for _key, _row in STRINGS.items():
    _row.extend(STRINGS_EXPANSION[_key])
del _missing, _extra, _key, _row

# Languages added with the international expansion: Lao, then the three Middle
# Eastern languages — Arabic, Hebrew and Persian — which read right-to-left
# and lay the interface out mirrored.
EXPANSION_2_LANGUAGES = ["lo", "ar", "he", "fa"]

# key: [lo, ar, he, fa]
STRINGS_EXPANSION_2: dict[str, list[str]] = {
    # --- Application shell -------------------------------------------------
    "nav.dashboard": ["ພາບລວມ", "نظرة عامة", "סקירה כללית", "نمای کلی"],
    "nav.smartScan": ["ສະແກນອັດສະລິຍະ", "فحص ذكي", "סריקה חכמה", "اسکن هوشمند"],
    "nav.junkCleanup": ["ລ້າງຂີ້ເຫຍື້ອ", "تنظيف الملفات غير المرغوبة", "ניקוי קבצי זבל", "پاک‌سازی فایل‌های زائد"],
    "nav.uninstaller": ["ການຖອນການຕິດຕັ້ງ", "إزالة التطبيقات", "הסרת אפליקציות", "حذف برنامه‌ها"],
    "nav.fileCleanup": ["ການລ້າງໄຟລ໌", "تنظيف الملفات", "ניקוי קבצים", "پاک‌سازی فایل‌ها"],
    "nav.storageAnalysis": ["ພື້ນທີ່ຈັດເກັບ", "التخزين", "אחסון", "حافظه"],
    "nav.settings": ["ການຕັ້ງຄ່າ", "الإعدادات", "הגדרות", "تنظیمات"],
    "nav.privacy": ["ຄວາມເປັນສ່ວນຕົວ", "الخصوصية", "פרטיות", "حریم خصوصی"],

    # --- Dashboard ---------------------------------------------------------
    "dashboard.scanCard.title": ["ຊອກຫາສິ່ງທີ່ລ້າງໄດ້ຢ່າງປອດໄພ", "اكتشف ما يمكن تنظيفه بأمان", "גלו מה אפשר לנקות בבטחה", "ببینید چه چیزهایی می‌توانند با اطمینان پاک شوند"],
    "dashboard.scanCard.subtitle": ["ແຄຊ໌, ໄຟລ໌ບັນທຶກ, ໂປຣແກຣມຕິດຕັ້ງ ແລະ ໄຟລ໌ຕົກຄ້າງ. ທຸກໆລາຍການສະແດງແຫຼ່ງທີ່ມາ ແລະ ຈຸດປະສົງກ່ອນການລຶບ.", "ذاكرة مؤقتة وسجلات وبرامج تثبيت وملفات متبقية. يعرض كل عنصر مصدره وغرضه قبل الإزالة.", "מטמונים, יומנים, מתקינים וקבצים שנותרו. כל פריט מציג את מקורו וייעודו לפני ההסרה.", "حافظه‌های نهانی، گزارش‌ها، نصب‌کننده‌ها و فایل‌های باقی‌مانده. هر مورد پیش از حذف، منبع و کاربردش را نشان می‌دهد."],
    "dashboard.startScan": ["ເລີ່ມສະແກນ", "بدء الفحص", "התחל סריקה", "شروع اسکن"],
    "dashboard.lastScan": ["ສະແກນຄັ້ງສຸດທ້າຍ: %@", "آخر فحص: %@", "סריקה אחרונה: %@", "آخرین اسکن: %@"],
    "dashboard.neverScanned": ["ຍັງບໍ່ໄດ້ສະແກນ", "لم يُفحص بعد", "טרם נסרק", "هنوز اسکن نشده"],
    "dashboard.diskUsed": ["ພື້ນທີ່ທີ່ໃຊ້ແລ້ວ", "المساحة المستخدمة", "שטח בשימוש", "فضای استفاده‌شده"],
    "dashboard.diskFree": ["ວ່າງ %@", "%@ متاح", "%@ פנוי", "%@ آزاد"],
    "dashboard.suggestedCleanup": ["ແນະນຳໃຫ້ຈັດກ່ອນ", "مقترح أولاً", "מוצע קודם", "پیشنهاد اول"],
    "dashboard.recentActivity": ["ກິດຈະກຳຫຼ້າສຸດ", "النشاط الأخير", "פעילות אחרונה", "فعالیت اخیر"],
    "dashboard.cleanupCompleted": ["ລ້າງສຳເລັດແລ້ວ", "اكتمل التنظيف", "הניקוי הושלם", "پاک‌سازی انجام شد"],
    "dashboard.scanCompleted": ["ສະແກນສຳເລັດແລ້ວ", "اكتمل الفحص", "הסריקה הושלמה", "اسکن انجام شد"],
    "dashboard.now": ["ຕອນນີ້", "الآن", "עכשיו", "اکنون"],
    "dashboard.lookSuggestions": ["ເບິ່ງຄຳແນະນຳ", "عرض الاقتراحات", "הצג הצעות", "مشاهده پیشنهادها"],
    # __MORE_KEYS__

    # --- Scan --------------------------------------------------------------
    "scan.phase.idle": ["ກຳລັງລໍຖ້າສະແກນ", "بانتظار الفحص", "ממתין לסריקה", "در انتظار اسکن"],
    "scan.phase.preparing": ["ກຳລັງກຽມໂຟນເດີ ແລະ ສິດ", "تحضير المجلدات والأذونات", "מכין תיקיות והרשאות", "آماده‌سازی پوشه‌ها و مجوزها"],
    "scan.phase.scanning": ["ກຳລັງສະແກນ", "جارٍ الفحص", "סורק", "در حال اسکن"],
    "scan.phase.indexing": ["ກຳລັງຄິດໄລ່ຂະໜາດ ແລະ ຈັດກຸ່ມໄຟລ໌ຊ້ຳ", "قياس الأحجام وتجميع المكررات", "מודד גדלים ומקבץ כפילויות", "اندازه‌گیری حجم‌ها و گروه‌بندی تکراری‌ها"],
    "scan.phase.ready": ["ສະແກນສຳເລັດແລ້ວ", "اكتمل الفحص", "הסריקה הושלמה", "اسکن کامل شد"],
    "scan.phase.cancelled": ["ຍົກເລີກການສະແກນແລ້ວ", "أُلغي الفحص", "הסריקה בוטלה", "اسکن لغو شد"],
    "scan.phase.partial": ["ບາງຕຳແໜ່ງອ່ານບໍ່ໄດ້", "تعذّرت قراءة بعض المواقع", "לא ניתן היה לקרוא חלק מהמיקומים", "خواندن برخی مکان‌ها ممکن نشد"],
    "scan.phase.failed": ["ສະແກນບໍ່ສຳເລັດ", "فشل الفحص", "הסריקה נכשלה", "اسکن ناموفق بود"],
    "scan.currentItem": ["ກຳລັງກວດ: %@", "جارٍ التحقق: %@", "בודק כעת: %@", "در حال بررسی: %@"],
    "scan.cancel": ["ຍົກເລີກການສະແກນ", "إلغاء الفحص", "בטל סריקה", "لغو اسکن"],
    "scan.results": ["ຜົນການສະແກນ", "النتائج", "תוצאות", "نتایج"],
    "scan.selectAll": ["ເລືອກທັງໝົດ", "تحديد الكل", "בחר הכול", "انتخاب همه"],
    "scan.deselectAll": ["ຍົກເລີກການເລືອກທັງໝົດ", "إلغاء تحديد الكل", "בטל בחירת הכול", "لغو انتخاب همه"],
    "scan.selectAllShown": ["ເລືອກທັງໝົດທີ່ສະແດງ (%d)", "تحديد المعروضين (%d)", "בחר את כל המוצגים (%d)", "انتخاب موارد نمایش‌داده‌شده (%d)"],
    "scan.nothingFound": ["ບໍ່ມີຫຍັງຕ້ອງລ້າງ", "لا شيء للتنظيف", "אין מה לנקות", "چیزی برای پاک‌سازی نیست"],
    "scan.nothingFoundDetail": ["Sift ບໍ່ພົບແຄຊ໌, ໄຟລ໌ບັນທຶກ, ໂປຣແກຣມຕິດຕັ້ງ ຫຼື ສິ່ງຕົກຄ້າງທີ່ຄວນລຶບ.", "لم يعثر Sift على ذاكرة مؤقتة أو سجلات أو برامج تثبيت أو بقايا تستحق الإزالة.", "Sift לא מצא מטמונים, יומנים, מתקינים או שיירים ששווה להסיר.", "Sift حافظهٔ نهانی، گزارش، نصب‌کننده یا باقی‌مانده‌ای که ارزش حذف داشته باشد نیافت."],
    "scan.partialNotice": ["ຂ້າມ %d ຕຳແໜ່ງແລ້ວ", "تم تخطي %d مواقع", "דולגו %d מיקומים", "%d مکان نادیده گرفته شد"],
    "scan.openSystemSettings": ["ເປີດການຕັ້ງຄ່າລະບົບ", "افتح إعدادات النظام", "פתח את הגדרות המערכת", "باز کردن تنظیمات سیستم"],
    "scan.skippedReason.permissionDenied": ["ຕຳແໜ່ງນີ້ຕ້ອງການສິດເພີ່ມເຕີມ.", "يحتاج هذا الموقع إلى إذن إضافي.", "מיקום זה דורש הרשאה נוספת.", "این مکان به مجوز بیشتری نیاز دارد."],
    "scan.skippedReason.protectedLocation": ["ເພື່ອປົກປ້ອງໄຟລ໌ຂອງທ່ານ, Sift ຈະບໍ່ແຕະຕຳແໜ່ງນີ້.", "لحماية ملفاتك، لا يلمس Sift هذا الموقع أبدًا.", "כדי להגן על הקבצים שלכם, Sift לעולם לא נוגע במיקום זה.", "برای محافظت از فایل‌هایتان، Sift هرگز به این مکان دست نمی‌زند."],
    "scan.skippedReason.fileNotFound": ["ລາຍການໄດ້ຫາຍໄປລະຫວ່າງການສະແກນ ຈຶ່ງຂ້າມໄປ.", "اختفى العنصر أثناء الفحص، فتم تخطيه.", "הפריט נעלם במהלך הסריקה ולכן דולג.", "مورد در طول اسکن ناپدید شد و از آن گذشتیم."],
    "scan.skippedReason.partialFailure": ["ບາງສ່ວນຂອງຕຳແໜ່ງນີ້ອ່ານບໍ່ໄດ້.", "تعذّرت قراءة جزء من هذا الموقع.", "לא ניתן היה לקרוא חלק ממיקום זה.", "بخشی از این مکان خوانده نشد."],
    "scan.skippedReason.timedOut": ["ໂຟນເດີນີ້ບໍ່ຕອບສະໜອງ, ຈຶ່ງຂ້າມໄປ.", "لم يستجب هذا المجلد، لذلك تم تخطيه.", "התיקייה לא הגיבה, ולכן דולגה.", "این پوشه پاسخ نداد، بنابراین نادیده گرفته شد."],
    # --- Cleanup -----------------------------------------------------------
    "cleanup.category.applicationCache": ["ແຄຊ໌ແອັບ", "ذاكرات التطبيقات المؤقتة", "מטמוני אפליקציות", "حافظهٔ نهانی برنامه‌ها"],
    "cleanup.category.logs": ["ໄຟລ໌ບັນທຶກ", "سجلات", "יומנים", "گزارش‌ها"],
    "cleanup.category.installers": ["ໂປຣແກຣມຕິດຕັ້ງເກົ່າ", "برامج تثبيت قديمة", "מתקינים ישנים", "نصب‌کننده‌های قدیمی"],
    "cleanup.category.temporaryFiles": ["ໄຟລ໌ຊົ່ວຄາວ", "ملفات مؤقتة", "קבצים זמניים", "فایل‌های موقت"],
    "cleanup.category.largeFiles": ["ໄຟລ໌ຂະໜາດໃຫຍ່", "ملفات كبيرة", "קבצים גדולים", "فایل‌های بزرگ"],
    "cleanup.category.oldFiles": ["ໄຟລ໌ເກົ່າ", "ملفات قديمة", "קבצים ישנים", "فایل‌های قدیمی"],
    "cleanup.category.duplicateFiles": ["ໄຟລ໌ຊ້ຳ", "ملفات مكررة", "קבצים משוכפלים", "فایل‌های تکراری"],
    "cleanup.category.applicationResidue": ["ສິ່ງຕົກຄ້າງຂອງແອັບ", "بقايا تطبيقات", "שיירי אפליקציות", "باقی‌ماندهٔ برنامه‌ها"],
    "cleanup.category.developerArtifacts": ["ໄຟລ໌ຜົນລັບຂອງການຄອມໄພລ໌", "مخرجات البناء", "תוצרי בנייה", "خروجی‌های ساخت"],


    "cleanup.explanation.cache": ["ແອັບຈະສ້າງໄຟລ໌ເຫຼົ່ານີ້ຄືນໃໝ່ເມື່ອເປີດຄັ້ງຕໍ່ໄປ.", "تعيد التطبيقات إنشاء هذه الملفات عند تشغيلها في المرة القادمة.", "האפליקציות ייצרו מחדש את הקבצים האלה בהפעלה הבאה.", "برنامه‌ها دفعهٔ بعد که اجرا شوند این فایل‌ها را دوباره می‌سازند."],
    "cleanup.explanation.logs": ["ໄຟລ໌ບັນທຶກທີ່ເກົ່າກວ່າ %d ວັນ. ບໍ່ກະທົບການເຮັດວຽກຂອງແອັບ.", "ملفات سجلات أقدم من %d يومًا. لا تؤثر على عمل التطبيقات.", "קובצי יומן בני יותר מ-%d ימים. אינם משפיעים על פעולת האפליקציות.", "فایل‌های گزارش قدیمی‌تر از %d روز. بر کار برنامه‌ها اثر نمی‌گذارند."],
    "cleanup.explanation.logsItem": ["ໄຟລ໌ບັນທຶກເກົ່າ. ການລຶບອອກບໍ່ກະທົບການເຮັດວຽກຂອງແອັບ.", "ملفات سجلات قديمة. إزالتها لا تغيّر عمل التطبيقات.", "קובצי יומן ישנים. הסרתם אינה משנה את פעולת האפליקציות.", "گزارش‌های قدیمی. حذفشان کار برنامه‌ها را تغییر نمی‌دهد."],
    "cleanup.explanation.systemLogsItem": ["ໄຟລ໌ບັນທຶກລະບົບເກົ່າ. ບາງອັນຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນຈຶ່ງອ່ານໄດ້.", "ملفات سجلات نظام قديمة. قراءة بعضها يتطلب الوصول الكامل إلى القرص.", "קובצי יומן מערכת ישנים. קריאת חלקם דורשת גישה מלאה לכונן.", "گزارش‌های قدیمی سیستم. خواندن برخی نیاز به دسترسی کامل به دیسک دارد."],
    "cleanup.explanation.installers": ["ໂປຣແກຣມຕິດຕັ້ງທີ່ໃຊ້ແລ້ວ. ທ່ານອາດຍັງຕ້ອງການ, ກະລຸນາຢືນຢັນກ່ອນ.", "برامج تثبيت استخدمتها بالفعل. قد تحتاجها بعدُ، فأكّد أولًا.", "מתקינים שכבר השתמשת בהם. ייתכן שעדיין תזדקק להם — אשר קודם.", "نصب‌کننده‌هایی که پیش‌تر استفاده کرده‌اید. شاید هنوز لازمشان داشته باشید؛ ابتدا تأیید کنید."],
    "cleanup.explanation.temporary": ["ໄຟລ໌ຊົ່ວຄາວທີ່ແອັບທິ້ງໄວ້.", "ملفات مؤقتة تركتها التطبيقات.", "קבצי עבודה זמניים שהשאירו האפליקציות.", "فایل‌های موقتی که برنامه‌ها جا گذاشته‌اند."],
    "cleanup.explanation.xcodeArchives": ["ບິວທີ່ເກັບໄວ້. ໂປເຈັກສາມາດເກັບຄືນໃໝ່ໄດ້ ແຕ່ບິວທີ່ເກັບໄວ້ນີ້ກູ້ຄືນບໍ່ໄດ້.", "عمليات بناء مؤرشفة. يمكن أرشفة المشروع من جديد، لكن هذا الأرشيف لا يمكن استعادته.", "בניות בארכיון. אפשר לארכב את הפרויקט מחדש, אבל אי אפשר לשחזר את הארכיון הזה.", "بیلدهای بایگانی‌شده. پروژه را می‌توان دوباره بایگانی کرد، اما این بایگانی قابل بازیابی نیست."],
    "cleanup.explanation.buildArtifacts": ["ຜົນລັບຈາກການຄອມໄພລ໌ ການຄອມໄພລ໌ຄັ້ງຕໍ່ໄປຈະສ້າງຂຶ້ນໃໝ່.", "مخرجات كتبها المترجم. إعادة البناء تنشئها من جديد.", "פלט שהמהדר כתב. הבנייה הבאה תיצור אותו מחדש.", "خروجی که کامپایلر نوشته است. ساخت بعدی دوباره آن را می‌سازد."],

    "cleanup.explanation.simulatorDevices": ["ອຸປະກອນຈຳລອງ ແລະ ທຸກຢ່າງທີ່ຕິດຕັ້ງຢູ່ໃນນັ້ນ. ສ້າງອຸປະກອນຄືນໃໝ່ໄດ້ ແຕ່ແອັບຂ້າງໃນຕ້ອງຕິດຕັ້ງໃໝ່.", "أجهزة المحاكي وكل ما ثُبِّت داخلها. يمكن إنشاء الجهاز من جديد، أما التطبيقات بداخله فتجب إعادة تثبيتها.", "התקני סימולטור וכל מה שמותקן בהם. אפשר ליצור את ההתקן מחדש; את האפליקציות שבתוכו צריך להתקין שוב.", "دستگاه‌های شبیه‌ساز و هر چیزی که در آن‌ها نصب شده است. دستگاه را می‌توان دوباره ساخت؛ برنامه‌های داخل آن باید دوباره نصب شوند."],
    "cleanup.explanation.largeFiles": ["ໄຟລ໌ທີ່ໃຫຍ່ກວ່າ %@. Sift ບໍ່ເດາະເດາະ: ທ່ານເປັນຜູ້ຕັດສິນວ່າຈະລຶບອັນໃດ.", "ملفات أكبر من %@. لا يخمّن Sift: أنت من يقرر ماذا يُزال.", "קבצים גדולים מ-%@. Sift לא מנחש: אתם מחליטים מה להסיר.", "فایل‌های بزرگ‌تر از %@. Sift حدس نمی‌زند: تصمیم حذف با شماست."],
    "cleanup.explanation.largeFilesItem": ["ໄຟລ໌ຂະໜາດໃຫຍ່. Sift ບໍ່ເດາະເດາະ: ທ່ານເປັນຜູ້ຕັດສິນວ່າຈະລຶບອັນໃດ.", "ملف كبير. لا يخمّن Sift: أنت من يقرر ماذا يُزال.", "קובץ גדול. Sift לא מנחש: אתם מחליטים מה להסיר.", "فایلی بزرگ. Sift حدس نمی‌زند: تصمیم حذف با شماست."],
    "cleanup.explanation.oldFiles": ["ບໍ່ໄດ້ແກ້ໄຂ %d ວັນ ແລະ ໃຫຍ່ກວ່າ 10 MB.", "لم تُعدَّل منذ %d يومًا وأكبر من 10 ميغابايت.", "לא השתנו %d ימים וגדולים מ-10 MB.", "%d روز تغییر نکرده و بزرگ‌تر از ۱۰ مگابایت هستند."],
    "cleanup.explanation.oldFilesItem": ["ດົນນານແລ້ວທີ່ບໍ່ໄດ້ແກ້ໄຂ ແລະ ໃຫຍ່ກວ່າ 10 MB.", "لم تُعدَّل منذ مدة طويلة وأكبر من 10 ميغابايت.", "לא השתנה זמן רב וגדול מ-10 MB.", "مدت‌هاست تغییر نکرده و بزرگ‌تر از ۱۰ مگابایت است."],
    "cleanup.explanation.duplicates": ["ເນື້ອໃນຄືກັນໝົດ. ເກັບໄວ້ໜຶ່ງ ລຶບທີ່ເຫຼືອ.", "محتوى متطابق. احتفظ بنسخة واحدة واحذف البقية.", "תוכן זהה. שמרו עותק אחד והסירו את השאר.", "محتوا یکسان است. یکی را نگه دارید و بقیه را حذف کنید."],
    "cleanup.explanation.residue": ["ສິ່ງຕົກຄ້າງຈາກແອັບທີ່ຖອນການຕິດຕັ້ງແລ້ວ.", "بقايا من تطبيق لم يعد مثبتًا.", "שיירים מאפליקציה שאינה מותקנת עוד.", "باقی‌ماندهٔ برنامه‌ای که دیگر نصب نیست."],
    "cleanup.explanation.residuePreferences": ["ໄຟລ໌ການຕັ້ງຄ່າທີ່ບໍ່ມີແອັບຕິດຕັ້ງຕໍ່ກັນ.", "ملف تفضيلات دون تطبيق مثبت مطابق.", "קובץ העדפות ללא אפליקציה מותקנת מתאימה.", "فایل تنظیمات بدون برنامهٔ نصب‌شدهٔ متناظر."],
    "cleanup.explanation.residueWebStorage": ["ຂໍ້ມູນເວັບຂອງແອັບທີ່ຖອນແລ້ວ.", "تخزين ويب لتطبيق لم يعد مثبتًا.", "אחסון אינטרנט של אפליקציה שאינה מותקנת עוד.", "حافظهٔ وب برنامه‌ای که دیگر نصب نیست."],
    "cleanup.explanation.residueGroupContainer": ["ຖັງຮ່ວມຂອງແອັບທີ່ຖອນແລ້ວ.", "حاوية مشتركة لتطبيق لم يعد مثبتًا.", "מיכל משותף של אפליקציה שאינה מותקנת עוד.", "کانتینر مشترک برنامه‌ای که دیگر نصب نیست."],
    "cleanup.explanation.savedState": ["ສະຖານະໜ້າຕ່າງທີ່ບັນທຶກໄວ້ສຳລັບແອັບທີ່ອອກຈາກການເຮັດວຽກແລ້ວ.", "حالة نوافذ محفوظة لتطبيقات لم تعد تعمل.", "מצב חלונות שנשמר לאפליקציות שאינן פועלות עוד.", "وضعیت پنجره‌های ذخیره‌شده برای برنامه‌هایی که دیگر باز نیستند."],

    "risk.safe.short": ["ປອດໄພ", "آمن", "בטוח", "امن"],
    "risk.review.short": ["ຕ້ອງຢືນຢັນ", "مراجعة", "לבדיקה", "نیازمند تأیید"],
    "risk.protected.short": ["ປ້ອງກັນໄວ້", "محمي", "מוגן", "محافظت‌شده"],
    "risk.safe.detail": ["ຈະສ້າງຄືນໂດຍອັດຕະໂນມັດ ຖ້າຕ້ອງການ. ເລືອກໄວ້ໂດຍຄ່າເລີ່ມຕົ້ນ.", "يُعاد إنشاؤه تلقائيًا عند الحاجة. محدد افتراضيًا.", "נוצר מחדש אוטומטית במידת הצורך. מסומן כברירת מחדל.", "در صورت نیاز خودکار بازسازی می‌شود. به‌طور پیش‌فرض انتخاب شده است."],
    "risk.review.detail": ["ໂດຍທົ່ວໄປລຶບໄດ້ ແຕ່ຄວນຢືນຢັນກ່ອນ.", "يمكن إزالته عادةً، لكن من الأفضل التأكيد.", "בדרך כלל אפשר להסיר, אבל עדיף לאשר.", "معمولاً قابل حذف است، اما بهتر است تأیید کنید."],
    "risk.protected.detail": ["Sift ຈະບໍ່ລຶບສິ່ງນີ້ ສະແດງເພື່ອຂໍ້ມູນເທົ່ານັ້ນ.", "لن يزله Sift. يُعرض للإعلام فقط.", "Sift לא יסיר זאת. מוצג למידע בלבד.", "Sift این را حذف نمی‌کند. فقط برای اطلاع نمایش داده می‌شود."],

    "cleanup.confirm.title": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ?", "نقل إلى المهملات؟", "להעביר אל פח האשפה؟", "به سطل بازیافت منتقل شود؟"],
    "cleanup.confirm.moveCount": ["ຍ້າຍ %d ລາຍການໄປຖັງຂີ້ເຫຍື້ອ, ລວມ %@", "نقل %d عنصرًا إلى المهملات، %@ إجمالًا", "העברת %d פריטים אל פח האשפה, %@ בסך הכול", "انتقال %d مورد به سطل بازیافت، در مجموع %@"],
    "cleanup.confirm.moveCountOne": ["ຍ້າຍ 1 ລາຍການໄປຖັງຂີ້ເຫຍື້ອ, ລວມ %@", "نقل عنصر واحد إلى المهملات، %@ إجمالًا", "העברת פריט אחד אל פח האשפה, %@ בסך הכול", "انتقال ۱ مورد به سطل بازیافت، در مجموع %@"],
    "cleanup.confirm.undoNotice": ["ທຸກຢ່າງຈະເຂົ້າຖັງຂີ້ເຫຍື້ອ ຈຶ່ງກູ້ຄືນໄດ້ຈົນກວ່າຈະລ້າງຖັງ.", "كل شيء يذهب إلى المهملات، لذا يمكنك استعادته حتى تفرغها.", "הכול יועבר אל פח האשפה, כך שאפשר לשחזר עד שתרוקנו אותו.", "همه چیز به سطل بازیافت می‌رود؛ تا زمان خالی کردنش می‌توانید بازگردانید."],
    "cleanup.confirm.selectedItems": ["ເລືອກແລ້ວ %d ລາຍການ", "تم تحديد %d", "נבחרו %d", "%d مورد انتخاب شد"],
    "cleanup.confirm.methodValue": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ (ກູ້ຄືນໄດ້)", "نقل إلى المهملات (قابل للاستعادة)", "העברה אל פח האשפה (ניתן לשחזור)", "انتقال به سطل بازیافت (قابل بازیابی)"],
    "cleanup.confirm.cancel": ["ຍົກເລີກ", "إلغاء", "ביטול", "لغو"],
    "cleanup.confirm.skipConfirmation": ["ຂ້າມການຢືນຢັນຄັ້ງຕໍ່ໄປ", "تخطي التأكيد في المرة القادمة", "לדלג על האישור בפעם הבאה", "دفعهٔ بعد از تأیید عبور کن"],
    "cleanup.confirm.riskWarning": ["ທ່ານໄດ້ເລືອກລາຍການທີ່ຕ້ອງຢືນຢັນ. ກວດເບິ່ງລາຍການກ່ອນສືບຕໍ່.", "لقد ضمّنت عناصر محددة للمراجعة. تحقق من القائمة قبل المتابعة.", "כללתם פריטים המסומנים לבדיקה. בדקו את הרשימה לפני ההמשך.", "مواردی که نیاز به بررسی دارند را گنجانده‌اید. پیش از ادامه فهرست را بازبینی کنید."],

    "cleanup.result.title": ["ການລ້າງສຳເລັດແລ້ວ", "اكتمل التنظيف", "הניקוי הסתיים", "پاک‌سازی تمام شد"],
    "cleanup.result.moved": ["ຍ້າຍ %d ລາຍການໄປຖັງຂີ້ເຫຍື້ອແລ້ວ", "نُقل %d عنصرًا إلى المهملات", "%d פריטים הועברו אל פח האשפה", "%d مورد به سطل بازیافت منتقل شد"],
    "cleanup.result.released": ["ສ້າງພື້ນທີ່ໄດ້ %@", "تم تحرير %@", "שוחרר %@", "%@ آزاد شد"],
    "cleanup.result.showTrash": ["ເບິ່ງຖັງຂີ້ເຫຍື້ອໃນ Finder", "عرض المهملات في Finder", "הצג את פח האשפה ב-Finder", "نمایش سطل بازیافت در فایندر"],
    "cleanup.result.undoHint": ["ກູ້ລາຍການຄືນຈາກຖັງຂີ້ເຫຍື້ອໄດ້ ຈົນກວ່າຈະລ້າງຖັງ.", "استعد العناصر من المهملات حتى تفرغها.", "אפשר לשחזר פריטים מפח האשפה עד שתרוקנו אותו.", "تا زمان خالی کردن سطل بازیافت می‌توانید موارد را بازگردانید."],
    "cleanup.result.details": ["ລາຍລະອຽດຂອງລາຍການ", "تفاصيل العناصر", "פרטי הפריטים", "جزئیات موارد"],
    "cleanup.result.exportReport": ["ສົ່ງອອກລາຍງານເປັນ PDF", "تصدير التقرير بصيغة PDF", "ייצוא הדוח כקובץ PDF", "خروجی گرفتن گزارش به‌صورت PDF"],

    "cleanup.failure.permissionDenied": ["ຕ້ອງການສິດເຂົ້າເຖິງດິສກ໌", "يحتاج إلى الوصول إلى القرص", "דורש גישה לכונן", "نیازمند دسترسی به دیسک"],
    "cleanup.failure.fileNotFound": ["ຖືກລຶບໄປແລ້ວ", "أُزيل بالفعل", "כבר הוסר", "قبلاً حذف شده"],
    "cleanup.failure.fileInUse": ["ກຳລັງໃຊ້ຢູ່, ຂ້າມໄປ", "قيد الاستخدام، تم تخطيه", "בשימוש, דולג", "در حال استفاده، رد شد"],
    "cleanup.failure.itemChanged": ["ມີການປ່ຽນແປງ, ຂ້າມໄປ", "تغيّر، تم تخطيه", "השתנה, דולג", "تغییر کرد، رد شد"],
    "cleanup.failure.volumeUnavailable": ["ດິສກ໌ຖືກຕັດການເຊື່ອມຕໍ່", "انقطع اتصال القرص", "הכונן התנתק", "دیسک جدا شده است"],
    "cleanup.failure.protectedLocation": ["ຕຳແໜ່ງທີ່ປ້ອງກັນໄວ້", "موقع محمي", "מיקום מוגן", "مکان محافظت‌شده"],
    "cleanup.failure.partialFailure": ["ສຳເລັດບາງສ່ວນ", "تم جزئيًا", "בוצע חלקית", "تا حدی انجام شد"],
    # --- Uninstaller -------------------------------------------------------
    "uninstall.search": ["ຄົ້ນຫາແອັບ", "البحث عن تطبيقات", "חיפוש אפליקציות", "جستجوی برنامه‌ها"],
    "uninstall.sort.name": ["ຊື່", "الاسم", "שם", "نام"],
    "uninstall.sort.size": ["ຂະໜາດ", "الحجم", "גודל", "اندازه"],
    "uninstall.sort.lastUsed": ["ໃຊ້ຫຼ້າສຸດ", "آخر استخدام", "שימוש אחרון", "آخرین استفاده"],
    "uninstall.noneInstalled": ["ບໍ່ພົບແອັບຂອງພາກສ່ວນທີສາມ", "لا توجد تطبيقات تابعة لجهات خارجية", "לא נמצאו אפליקציות של צד שלישי", "برنامهٔ شخص ثالثی یافت نشد"],
    "uninstall.systemApp": ["ຖອນການຕິດຕັ້ງບໍ່ໄດ້", "لا يمكن إزالته", "לא ניתן להסיר", "قابل حذف نیست"],
    "uninstall.systemAppDetail": ["Sift ຈັດການສະເພາະແອັບທີ່ທ່ານຕິດຕັ້ງເອງ.", "يزيل Sift التطبيقات التي ثبّتها بنفسك فقط.", "Sift מסיר רק אפליקציות שהתקנתם בעצמכם.", "Sift فقط برنامه‌هایی را حذف می‌کند که خودتان نصب کرده‌اید."],
    "uninstall.needsReview": ["ຕ້ອງການທ່ານຢືນຢັນ", "تحتاج إلى تأكيدك", "דורשים את אישורכם", "نیازمند تأیید شما"],
    "uninstall.reason.bundleIdentifier": ["ຊື່ນີ້ຄື bundle identifier ຂອງແອັບນີ້.", "الاسم هو معرّف الحزمة لهذا التطبيق.", "השם הוא מזהה ה-bundle של אפליקציה זו.", "نام، شناسهٔ بستهٔ همین برنامه است."],
    "uninstall.reason.identifierPrefix": ["ຊື່ນີ້ຂຶ້ນຕົ້ນດ້ວຍ bundle identifier ຂອງແອັບນີ້.", "الاسم يبدأ بمعرّف الحزمة لهذا التطبيق.", "השם מתחיל במזהה ה-bundle של אפליקציה זו.", "نام با شناسهٔ بستهٔ همین برنامه آغاز می‌شود."],
    "uninstall.reason.applicationName": ["ຊື່ກົງກັບຊື່ແອັບ ແລະ ຢູ່ໃນໂຟນເດີທີ່ macOS ເກັບຂໍ້ມູນຕໍ່ແອັບ.", "الاسم يطابق اسم التطبيق تمامًا، في مجلد يحتفظ به macOS لكل تطبيق.", "השם תואם בדיוק לשם האפליקציה, בתיקייה ש-macOS משתמש בה לכל אפליקציה.", "نام دقیقاً با نام برنامه یکسان است و در پوشه‌ای است که مک‌او‌اس برای هر برنامه نگه می‌دارد."],
    "uninstall.reason.identifierSuffix": ["ຊື່ນີ້ກົງກັບສ່ວນທ້າຍຂອງ bundle identifier ຂອງແອັບນີ້.", "الاسم يطابق الجزء الأخير من معرّف الحزمة لهذا التطبيق.", "השם תואם לחלק האחרון של מזהה ה-bundle של אפליקציה זו.", "نام با بخش پایانی شناسهٔ بستهٔ همین برنامه مطابقت دارد."],
    "uninstall.reason.appGroup": ["ຄອນເທນເນີນີ້ຢູ່ໃນກຸ່ມແອັບທີ່ແອັບນີ້ປະກາດ.", "الحاوية تنتمي إلى مجموعة تطبيقات يعلنها هذا التطبيق.", "המכל שייך לקבוצת אפליקציות שהאפליקציה הזו מצהירה עליה.", "این محفظه به گروه برنامه‌ای تعلق دارد که این برنامه اعلام می‌کند."],
    "uninstall.copyGroupIdentifier": ["ສຳເນົາຕົວະລະບຸກຸ່ມ", "نسخ معرِّف المجموعة", "העתקת מזהה הקבוצה", "رونوشت شناسهٔ گروه"],
    "uninstall.appRunning": ["%@ ກຳລັງເຮັດວຽກ. ອອກຈາກແອັບກ່ອນ ຖ້າບໍ່ດັ່ງນັ້ນ Sift ຈະຂ້າມໄຟລ໌ທີ່ຖືກເປີດຢູ່.", "%@ قيد التشغيل. أغلقه قبل الإزالة، وإلا سيتخطى Sift الملفات المفتوحة.", "%@ פועל כעת. סגרו אותו לפני ההסרה, אחרת Sift ידלג על הקבצים הפתוחים.", "%@ در حال اجراست. پیش از حذف آن را ببندید، در غیر این صورت Sift فایل‌های در حال استفاده را نادیده می‌گیرد."],
    "uninstall.quitFailed": ["Sift ຂໍໃຫ້ %@ ອອກບໍ່ສຳເລັດ. ອອກເອງກ່ອນ ແລ້ວລອງໃໝ່.", "لم يتمكن Sift من مطالبة %@ بالإغلاق. أغلقه يدويًا وحاول مجددًا.", "Sift לא הצליח לבקש מ-%@ להיסגר. סגרו אותו ידנית ונסו שוב.", "Sift نتوانست از %@ بخواهد که ببندد. آن را دستی ببندید و دوباره تلاش کنید."],
    "uninstall.noRelatedFiles": ["ບໍ່ພົບໄຟລ໌ທີ່ກ່ຽວຂ້ອງ.", "لم يتم العثور على ملفات مرتبطة.", "לא נמצאו קבצים קשורים.", "فایل مرتبطی پیدا نشد."],
    "uninstall.selectApp": ["ເລືອກແອັບເພື່ອເບິ່ງວ່າຈະມີຫຍັງຖືກລຶບ.", "اختر تطبيقًا لترى ما سيُزال.", "בחרו אפליקציה כדי לראות מה יוסר.", "برنامه‌ای را انتخاب کنید تا ببینید چه چیزی حذف می‌شود."],

    # --- File cleanup ------------------------------------------------------
    "files.mode.large": ["ໄຟລ໌ຂະໜາດໃຫຍ່", "ملفات كبيرة", "קבצים גדולים", "فایل‌های بزرگ"],
    "files.mode.old": ["ໄຟລ໌ເກົ່າ", "ملفات قديمة", "קבצים ישנים", "فایل‌های قدیمی"],
    "files.mode.duplicates": ["ໄຟລ໌ຊ້ຳ", "مكررات", "כפילויות", "تکراری‌ها"],
    "files.duplicateGroups": ["%d ກຸ່ມໄຟລ໌ຊ້ຳ, ສ້າງພື້ນທີ່ໄດ້ %@", "%d مجموعات مكررة، %@ قابل للاستعادة", "%d קבוצות כפילויות, %@ לפינוי", "%d گروه تکراری، %@ قابل آزادسازی"],
    "files.duplicateGroupsShown": ["ສະແດງ %d / %d ກຸ່ມ", "عرض %d من %d مجموعات", "מוצגות %d מתוך %d קבוצות", "نمایش %d از %d گروه"],
    "files.groupMembers": ["%d ສຳເນົາ", "%d نسخًا", "%d עותקים", "%d نسخه"],
    "files.keepThis": ["ເກັບອັນນີ້ໄວ້", "الاحتفاظ بهذا", "לשמור על זה", "این را نگه دار"],
    "files.noDuplicates": ["ບໍ່ພົບໄຟລ໌ຊ້ຳ", "لم يتم العثور على ملفات مكررة", "לא נמצאו קבצים משוכפלים", "فایل تکراری پیدا نشد"],
    "files.revealInFinder": ["ສະແດງໃນ Finder", "عرض في Finder", "הצג ב-Finder", "نمایش در فایندر"],
    "files.requiresAuthorization": ["Sift ສະແກນດາວໂຫລດ, ໜ້າຈໍຫຼັກ ແລະ ໂຟນເດີທີ່ທ່ານເລືອກ. ເພີ່ມໂຟນເດີເພື່ອໃສ່ໃນການສະແກນ.", "يفحص Sift التنزيلات وسطح المكتب والمجلدات التي تختارها. أضف مجلدًا لإدراجه.", "Sift סורק הורדות, שולחן עבודה ותיקיות שתבחרו. הוסיפו תיקייה כדי לכלול אותה.", "Sift دانلودها، میزکار و پوشه‌هایی که انتخاب می‌کنید را اسکن می‌کند. برای گنجاندن، پوشه‌ای بیفزایید."],
    "files.addFolder": ["ເພີ່ມໂຟນເດີ", "إضافة مجلد", "הוסף תיקייה", "افزودن پوشه"],

    # --- System diagnostics ------------------------------------------------
    "diagnostics.category.spotlightIndex": ["ດັດຊະນີ Spotlight", "فهرس Spotlight", "אינדקס Spotlight", "نمایهٔ Spotlight"],
    "diagnostics.category.coreSpotlightIndex": ["ເມຕາດຕາການຄົ້ນຫາ", "بيانات وصفية للبحث", "נתוני חיפוש", "فرادادهٔ جست‌وجو"],
    "diagnostics.category.developerIndex": ["ດັດຊະນີນັກພັດທະນາ", "فهرس التطوير", "אינדקס פיתוח", "نمایهٔ توسعه"],
    "diagnostics.category.applicationDatabase": ["ຖານຂໍ້ມູນແອັບ", "قاعدة بيانات التطبيق", "מסד נתונים של האפליקציה", "پایگاه دادهٔ برنامه"],
    "diagnostics.category.filesystemSnapshot": ["ຮູບ Snapshot APFS", "لقطة APFS", "תמונת מצב APFS", "عکس فوری APFS"],
    "diagnostics.category.systemCache": ["ແຄຊ໌ລະບົບ", "ذاكرة النظام المؤقتة", "מטמון המערכת", "حافظهٔ نهانی سیستم"],
    "diagnostics.category.systemData": ["ຂໍ້ມູນລະບົບ", "بيانات النظام", "נתוני מערכת", "داده‌های سیستم"],
    "diagnostics.category.userData": ["ຂໍ້ມູນຂອງທ່ານ", "بياناتك", "הנתונים שלכם", "داده‌های شما"],
    "diagnostics.category.unknown": ["ຍັງບໍ່ຈັດປະເພດ", "غير مصنّف", "לא מסווג", "دسته‌بندی‌نشده"],
    "diagnostics.status.cleanable": ["ລ້າງໄດ້", "يمكن تنظيفه", "ניתן לניקוי", "قابل پاک‌سازی"],
    "diagnostics.status.rebuildable": ["ສ້າງຄືນໄດ້", "يمكن إعادة بنائه", "ניתן לבנות מחדש", "قابل بازسازی"],
    "diagnostics.status.protected": ["ປ້ອງກັນໄວ້", "محمي", "מוגן", "محافظت‌شده"],
    "diagnostics.status.unknown": ["ຍັງບໍ່ຕັດສິນ", "بلا تقييم", "ללא הערכה", "بدون ارزیابی"],
    "diagnostics.remediation.trash": ["ຈະຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ ຫຼັງທ່ານຢືນຢັນ", "ينتقل إلى المهملات بعد تأكيدك", "יועבר לפח האשפה לאחר האישור שלכם", "پس از تأیید شما به سطل بازیافت منتقل می‌شود"],
    "diagnostics.remediation.spotlight": ["ສ້າງຄືນດ້ວຍ Spotlight: mdutil -E", "أعد بناءه عبر Spotlight: mdutil -E", "לבנות מחדש באמצעות Spotlight: ‏mdutil -E", "با Spotlight بازسازی کنید: mdutil -E"],
    "diagnostics.remediation.owningApplication": ["ສ້າງຄືນຈາກເຄື່ອງມືທີ່ສ້າງມັນ", "أعد بناءه عبر الأداة التي أنشأته", "לבנות מחדש מהכלי שיצר אותו", "با ابزاری که ساخته بازسازی کنید"],
    "diagnostics.remediation.inspectOnly": ["ສະແດງເພື່ອຂໍ້ມູນເທົ່ານັ້ນ, Sift ບໍ່ແຕະຕ້ອງ", "للإعلام فقط: لا يتدخل Sift", "למידע בלבד: Sift אינו מתערב", "فقط برای اطلاع: Sift دخالتی ندارد"],
    "diagnostics.coverage.complete": ["ຜົນການນີ້ຄຸມຄົບຊ່ອງທີ່ສະເໝີມາ.", "هذه النتيجة تغطي كل النطاق المطلوب.", "התוצאה הזו מכסה את כל ההיקף המבוקש.", "این نتیجه کل محدودهٔ خواسته‌شده را پوشش می‌دهد."],
    "diagnostics.coverage.partial": ["ບາງສ່ວນວັດແທກບໍ່ໄດ້ ຈຶ່ງຕົວເລກລວມເປັນພຽງຂອບລຸ່ມ.", "تعذّر قياس جزء من النطاق، لذا فإن الإجماليات حد أدنى.", "חלק מההיקף לא נמדד, ולכן הסכומים הם גבול תחתון.", "بخشی از محدوده اندازه‌گیری نشد، پس جمع‌ها حد پایین‌اند."],
    "diagnostics.coverage.permissionDenied": ["ບາງຕຳແໜ່ງຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ ຈຶ່ງວັດແທກໄດ້.", "تحتاج بعض المواقع إلى الوصول الكامل إلى القرص لتُقاس.", "חלק מהמיקומים דורש גישה מלאה לכונן כדי להימדד.", "برخی مکان‌ها برای اندازه‌گیری به دسترسی کامل به دیسک نیاز دارند."],
    "diagnostics.coverage.volumeUnavailable": ["ມີຣະບົບຫນຶ່ງທີ່ໃຊ້ບໍ່ໄດ້ແລ້ວ ຈຶ່ງບໍ່ວັດແທກ.", "لم يعد حجم واحدًا متاحًا، فلم يُقَس.", "כונן אחד אינו זמין עוד ולא נמדד.", "یک حجم دیگر در دسترس نیست و اندازه‌گیری نشد."],
    "diagnostics.explanation.volumeChild": ["ໄດເຣັກໂທຣີຢູ່ລະດັບເທິງສຸດຂອງຣະບົບ.", "دليل في المستوى الأعلى من الحجم.", "ספרייה ברמה העליונה של הכונן.", "پوشه‌ای در بالاترین سطح حجم."],
    "diagnostics.explanation.systemData": ["ເປັນສ່ວນໜຶ່ງຂອງ macOS ຫຼື ຄັງສະຄຣິບຂອງມັນ. ກິນພື້ນທີ່ ແຕ່ລຶບອອກບໍ່ໄດ້.", "جزء من macOS أو مكتباته. يشغل مساحة ولا يمكن إزالته.", "חלק מ-macOS או מהספריות שלו. תופס שטח ואינו ניתן להסרה.", "بخشی از مک‌او‌اس یا کتابخانه‌هایش. فضا اشغال می‌کند و قابل حذف نیست."],
    "diagnostics.explanation.spotlightIndexed": ["ດັດຊະນີ Spotlight ຂອງຣະບົບນີ້; ການຈັດດັດຊະນີເປີດຢູ່. macOS ສ້າງຄືນໄດ້ດ້ວຍ mdutil -E; ຖ້າຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ ການຄົ້ນຫາຈະໃຊ້ບໍ່ໄດ້ຈົນກວ່າຈະສ້າງຄືນສຳເລັດ.", "فهرس Spotlight لهذا الحجم؛ الفهرسة مفعّلة. يعيد macOS بناءه عبر mdutil -E — نقله إلى المهملات يجعل البحث فقط غير متاح حتى تكتمل إعادة البناء.", "אינדקס ה-Spotlight של הכונן הזה; האינדוקס פעיל. macOS בונה אותו מחדש עם mdutil -E — העברה אל פח האשפה רק תשבית את החיפוש עד לסיום הבנייה מחדש.", "نمایهٔ Spotlight این حجم؛ نمایه‌سازی روشن است. مک‌او‌اس آن را با mdutil -E بازسازی می‌کند — انتقال به سطل بازیافت فقط تا پایان بازسازی، جست‌وجو را از کار می‌اندازد."],
    "diagnostics.explanation.spotlightNotIndexed": ["ດັດຊະນີ Spotlight ຂອງຣະບົບນີ້; ຕອນນີ້ການຈັດດັດຊະນີປິດຢູ່. ໄດເຣັກໂທຣີນີ້ຢູ່ໃນການດູແລຂອງ macOS.", "فهرس Spotlight لهذا الحجم؛ تظهر الفهرسة كمعطّلة. الدليل تديره macOS.", "אינדקס ה-Spotlight של הכונן הזה; האינדוקס מדווח ככבוי. הספרייה מנוהלת בידי macOS.", "نمایهٔ Spotlight این حجم؛ نمایه‌سازی در حال حاضر خاموش گزارش می‌شود. این پوشه را مک‌او‌اس مدیریت می‌کند."],
    "diagnostics.explanation.spotlightStateUnknown": ["ດັດຊະນີ Spotlight ຂອງຣະບົບນີ້. ອ່ານສະຖານະປັດຈຸບັນຂອງ Spotlight ບໍ່ໄດ້.", "فهرس Spotlight لهذا الحجم. تعذّرت قراءة ما يفعله Spotlight الآن.", "אינדקס ה-Spotlight של הכונן הזה. לא ניתן היה לקרוא מה Spotlight עושה כרגע.", "نمایهٔ Spotlight این حجم. آن‌که Spotlight اکنون چه می‌کند خوانده نشد."],
    "diagnostics.explanation.spotlightUnreadable": ["ດັດຊະນີ Spotlight ຂອງຣະບົບນີ້. ອ່ານຂະໜາດບໍ່ໄດ້: ຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ.", "فهرس Spotlight لهذا الحجم. تعذّرت قراءة حجمه: يلزم الوصول الكامل إلى القرص.", "אינדקס ה-Spotlight של הכונן הזה. לא ניתן היה לקרוא את גודלו: נדרשת גישה מלאה לכונן.", "نمایهٔ Spotlight این حجم. خواندن اندازه‌اش ممکن نشد: دسترسی کامل به دیسک لازم است."],
    "diagnostics.explanation.coreSpotlight": ["ເມຕາດຕາການຄົ້ນຫາທີ່ລະບົບເກັບໄວ້ສຳລັບເນື້ອໃນຂອງທ່ານ ເຊັ່ນ ໄມລ໌ ແລະ ຂໍ້ຄວາມ. ການສ້າງຄືນອາດໃຊ້ເວລາ ແລະ ການຄົ້ນຫາຈະບໍ່ຄົບຖ້ວນຈົນກວ່າຈະສຳເລັດ.", "بيانات وصفية للبحث يحتفظ بها النظام لمحتواك، كالبريد والرسائل. إعادة بنائها تستغرق وقتًا ويبقى البحث ناقصًا حتى تنتهي.", "נתוני חיפוש שהמערכת שומרת עבור התוכן שלכם, כגון דואר והודעות. בנייה מחדש לוקחת זמן והחיפוש בלתי שלם עד לסיומה.", "فرادادهٔ جست‌وجویی که سیستم برای محتوای شما — مثل ایمیل و پیام‌ها — نگه می‌دارد. بازسازی زمان می‌برد و تا پایان آن جست‌وجو ناقص است."],
    "diagnostics.explanation.coreSpotlightUnreadable": ["ເມຕາດຕາການຄົ້ນຫາທີ່ລະບົບເກັບໄວ້ສຳລັບເນື້ອໃນຂອງທ່ານ. ອ່ານຂະໜາດບໍ່ໄດ້: ຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ.", "بيانات وصفية للبحث يحتفظ بها النظام لمحتواك. تعذّرت قراءة حجمها: يلزم الوصول الكامل إلى القرص.", "נתוני חיפוש שהמערכת שומרת עבור התוכן שלכם. לא ניתן היה לקרוא את גודלם: נדרשת גישה מלאה לכונן.", "فرادادهٔ جست‌وجویی که سیستم برای محتوای شما نگه می‌دارد. خواندن اندازه‌اش ممکن نشد: دسترسی کامل به دیسک لازم است."],
    "diagnostics.explanation.developerIndex": ["ດັດຊະນີທີ່ເຄື່ອງມືພັດທະນາສ້າງໄວ້ໃຫ້ໂຄງການນີ້. ເຄື່ອງມືຈະສ້າງຄືນເມື່ອຕ້ອງການ; ກ່ອນໜ້ານັ້ນ ການສົມບູນໂຄດ ແລະ ການຄົ້ນຫາສັນຍາລັກ ຈະຊ້າລົງ.", "فهرس بناه أداة تطوير لهذا المشروع. تعيد الأداة بناءه عند الطلب؛ وحتى ذلك الحين يكون الإكمال التلقائي والبحث عن الرموز أبطأ.", "אינדקס שכלי פיתוח בנה לפרויקט זה. הכלי בונה אותו מחדש לפי דרישה; עד אז השלמת הקוד וחיפוש סמלים איטיים יותר.", "نمایه‌ای که یک ابزار توسعه برای این پروژه ساخته است. ابزار در صورت نیاز آن را بازسازی می‌کند؛ تا آن زمان تکمیل کد و جست‌وجوی نمادها کندترند."],
    "diagnostics.explanation.developerData": ["ຂໍ້ມູນສ້າງ ແລະ ແຄຊ໌ທີ່ເຄື່ອງມືພັດທະນາເກັບໄວ້ນີ້. Sift ບໍ່ຕັດສິນວ່າໂຄງການສ້າງຄືນຫຍັງໄດ້ ຈຶ່ງບໍ່ສະເໜີສິ່ງເຫຼົ່ານີ້ເປັນລາຍການລຶບ.", "بيانات بناء وذاكرات مؤقتة يحتفظ بها أداة تطوير هنا. لا يحكم Sift بما يستطيع المشروع إعادة بنائه، لذا لا يُعرض من هنا شيء للإزالة.", "נתוני בנייה ומטמונים שכלי פיתוח שומר כאן. Sift אינו שופט מה הפרויקט יכול לבנות מחדש, ולכן כאן לא מוצע דבר להסרה.", "داده‌های ساخت و حافظه‌های نهانی که یک ابزار توسعه اینجا نگه می‌دارد. Sift دربارهٔ آن‌چه پروژه می‌تواند بازسازی کند قضاوت نمی‌کند، پس هیچ‌چیز از اینجا برای حذف پیشنهاد نمی‌شود."],
    "diagnostics.explanation.snapshots": ["Snapshot ທ້ອງຖິ່ນ APFS. ເກັບສະຖານະຣະບົບ, macOS ຈັດການຫຍໍ້ເອງ, ແລະ ລະບົບບໍ່ລາຍງານຂະໜາດຂອງແຕ່ລະອັນ.", "لقطات APFS محلية. تحفظ حالة الحجم، يقلّصها macOS بنفسه، والنظام لا يبلّغ عن حجم كل لقطة.", "תמונות מצב מקומיות של APFS. הן שומרות את מצב הכונן, macOS מדלל אותן בעצמו, והמערכת אינה מדווחת על גודל כל אחת.", "عکس‌های فوری محلی APFS. وضعیت حجم را نگه می‌دارند، مک‌او‌اس خودش آن‌ها را کاهش می‌دهد و سیستم اندازهٔ هر کدام را گزارش نمی‌کند."],
    "diagnostics.coverage.note": ["ເປີດການຕັ້ງຄ່າລະບົບ ອະນຸຍາດສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ ແລ້ວວິນິດໄສຄືນໃໝ່.", "افتح إعدادات النظام، امنح الوصول الكامل إلى القرص، ثم أعد التحليل.", "פתחו את הגדרות המערכת, העניקו גישה מלאה לכונן והריצו את הניתוח שוב.", "تنظیمات سیستم را باز کنید، دسترسی کامل به دیسک بدهید و سپس تحلیل را دوباره اجرا کنید."],
    "diagnostics.section.protected": ["ປ້ອງກັນໄວ້ ແຕ່ກິນພື້ນທີ່ຫຼາຍ", "محمي لكنه كبير", "מוגן אך גדול", "محافظت‌شده اما بزرگ"],
    "diagnostics.section.rebuildable": ["ສ້າງຄືນໄດ້", "يمكن إعادة بنائها", "ניתנים לבנייה מחדש", "قابل بازسازی"],
    "diagnostics.section.snapshots": ["Snapshot", "لقطات", "תמונות מצב", "عکس‌های فوری"],
    "diagnostics.section.skipped": ["ອ່ານບໍ່ໄດ້", "لم تُقرأ", "לא ניתנו לקריאה", "خوانده نشد"],
    "diagnostics.empty": ["ໃນຊ່ອງນີ້ບໍ່ພົບຫຍັງທີ່ກິນພື້ນທີ່ຫຼາຍ.", "لم يُعثر على شيء كبير في هذا النطاق.", "בהיקף זה לא נמצא דבר גדול.", "در این محدوده چیز بزرگی یافت نشد."],
    "diagnostics.note.approximate": ["ຂະໜາດເປັນຄ່າປະມານ: ການກ໋ອບ ແລະ Snapshot ເຮັດໃຫ້ພື້ນທີ່ທີ່ຈັດສັນບໍ່ບວກກັນງ່າຍໆ.", "الأحجام تقديرية: النسخ المتطابقة واللقطات تجعل المساحة المخصصة غير قابلة للجمع المباشر.", "הגדלים הם הערכות: שכפולים ותמונות מצב הופכים את השטח המוקצה לבלתי-ניתן לחיבור פשוט.", "اندازه‌ها تخمینی‌اند: کپی‌های همسان و عکس‌های فوری باعث می‌شوند فضای تخصیص‌یافته جمع‌شدنی ساده نباشد."],
    "diagnostics.note.readOnly": ["ການວິນິດໄສອ່ານຢ່າງດຽວ. ບໍ່ມີຫຍັງຖືກລຶບອອກໃນນີ້; ຖ້າລ້າງ ຍັງຜ່ານການຢືນຢັນປົກກະຕິ.", "التشخيص يقرأ فقط. لا يُزال شيء هنا، وأي تنظيف يمر بالتأكيد المعتاد.", "האבחון רק קורא. כאן לא מוסר דבר, וכל ניקוי עובר את האישור הרגיל.", "عیب‌یابی فقط می‌خواند. اینجا هیچ‌چیز حذف نمی‌شود و پاک‌سازی همچنان از تأیید معمول می‌گذرد."],

    "files.manageScope": ["ຈັດການໃນການຕັ້ງຄ່າ", "إدارة في الإعدادات", "לנהל בהגדרות", "مدیریت در تنظیمات"],
    "settings.group.authorized": ["ໂຟນເດີທີ່ໄດ້ຮັບອະນຸຍາດ", "المجلدات المصرّح بها", "תיקיות מורשות", "پوشه‌های مجاز"],
    "settings.authorized.empty": ["ຍັງບໍ່ໄດ້ອະນຸຍາດຫຍັງເລີຍ. ໂຟນເດີທີ່ເພີ່ມທີ່ນີ້ຈະຖືກສະແກນ ແລະ ໃຊ້ຊອກຫາໄຟລ໌ຊ້ຳ.", "لم يُصرّح بأي شيء بعد. المجلدات التي تضيفها هنا تُفحص وتُستخدم للعثور على المكررات.", "עדיין לא אושר דבר. תיקיות שתוסיפו כאן ייסרקו וישמשו למציאת כפילויות.", "هنوز هیچ‌چیز مجاز نشده است. پوشه‌هایی که اینجا می‌افزایید اسکن می‌شوند و برای یافتن تکراری‌ها به کار می‌روند."],
    "settings.staleThreshold": ["ເກນການເກົ່າ", "حد القدم", "סף אי-עדכניות", "آستانهٔ قدیمی‌شدن"],
    "storage.includeVolume": ["ໃສ່ການວິນິດໄສທົ່ວຣະບົບນຳ", "تضمين تشخيص الحجم بالكامل", "לכלול אבחון הכונן כולו", "گنجاندن عیب‌یابی کل حجم"],
    "storage.scopeNote": ["ປະເພດໄຟລ໌ນັບໂຟນເດີບ້ານຂອງທ່ານ ແລະ ໂຟນເດີທີ່ໄດ້ຮັບອະນຸຍາດໃນດິສກ໌ນີ້; ສະວິດຈະເພີ່ມການວິນິດໄສທົ່ວຣະບົບ.", "تغطي فئات الملفات مجلدك الرئيسي والمجلدات المصرّح بها على هذا القرص. يضيف المفتاح تشخيص الحجم بالكامل.", "קטגוריות הקבצים מכסות את התיקייה הביתית שלכם ותיקיות מורשות בכונן זה. המתג מוסיף אבחון מערכת של הכונן כולו.", "دسته‌های فایل پوشهٔ خانهٔ شما و پوشه‌های مجاز روی این دیسک را در بر می‌گیرند. کلید، عیب‌یابی کل حجم را می‌افزاید."],
    "settings.authorized.unavailable": ["ໃຊ້ບໍ່ໄດ້ໃນເຊດຊັນນີ້", "غير متاح في هذه الجلسة", "לא זמין בהפעלה זו", "در این نشست در دسترس نیست"],
    "files.scopeTitle": ["ໂຟນເດີທີ່ທ່ານເພີ່ມ", "المجلدات التي أضفتها", "התיקיות שהוספתם", "پوشه‌هایی که افزوده‌اید"],
    "settings.removeLicense": ["ເອົາລະຫັດໃບອະນຸຍາດທີ່ເກັບໄວ້ອອກ", "إزالة مفتاح الترخيص المحفوظ", "הסרת מפתח הרישיון השמור", "حذف کلید مجوز ذخیره‌شده"],

    # --- Storage -----------------------------------------------------------
    "storage.title": ["ພື້ນທີ່ຈັດເກັບ", "التخزين", "אחסון", "حافظه"],
    "storage.used": ["ໃຊ້ໄປ %@ ຈາກ %@ ت", "‏%@ مستخدم من %@", "‏%@ בשימוש מתוך %@", "‏%@ از %@ استفاده شده"],
    "storage.byType": ["ຕາມປະເພດໄຟລ໌", "حسب نوع الملف", "לפי סוג קובץ", "بر اساس نوع فایل"],
    "storage.type.images": ["ຮູບພາບ", "صور", "תמונות", "تصویرها"],
    "storage.type.video": ["ວິດີໂອ", "فيديو", "וידאו", "ویدیو"],
    "storage.type.audio": ["ສຽງ", "صوت", "אודיו", "صدا"],
    "storage.type.documents": ["ເອກະສານ", "مستندات", "מסמכים", "اسناد"],
    "storage.type.archives": ["ໄຟລ໌ບີບອັດ", "أرشيفات", "ארכיונים", "آرشیوها"],
    "storage.type.code": ["ໂຄດ", "شفرة برمجية", "קוד", "کد"],
    "storage.type.data": ["ຂໍ້ມູນ", "بيانات", "נתונים", "داده‌ها"],
    "storage.type.other": ["ອື່ນໆ", "أخرى", "אחר", "سایر"],
    "storage.topFiles": ["ໄຟລ໌ໃຫຍ່ສຸດ", "أكبر الملفات", "הקבצים הגדולים", "بزرگ‌ترین فایل‌ها"],
    "storage.topDirectories": ["ໂຟນເດີໃຫຍ່ສຸດ", "أكبر المجلدات", "התיקיות הגדולות", "بزرگ‌ترین پوشه‌ها"],
    "storage.analyze": ["ວິເຄາະພື້ນທີ່ຈັດເກັບ", "تحليل التخزين", "ניתוח האחסון", "تحلیل حافظه"],
    "storage.start": ["ເລີ່ມການວິເຄາະ", "بدء التحليل", "התחל ניתוח", "شروع تحلیل"],
    "storage.reanalyze": ["ວິເຄາະຄືນໃໝ່", "تحليل مجددًا", "נתח שוב", "تحلیل دوباره"],
    "storage.cancelAnalysis": ["ຍົກເລີກການວິເຄາະ", "إلغاء التحليل", "בטל ניתוח", "لغو تحلیل"],
    "storage.lastAnalyzed": ["ວິເຄາະຄັ້ງສຸດທ້າຍ: %@", "آخر تحليل: %@", "נותח לאחרונה: %@", "آخرین تحلیل: %@"],
    "storage.analysing": ["ກຳລັງວິເຄາະ…", "جارٍ التحليل…", "מנתח…", "در حال تحلیل…"],
    "storage.diskDisconnected": ["ດິສກ໌ນີ້ຖືກຕັດການເຊື່ອມຕໍ່ແລ້ວ. ກະລຸນາເຊື່ອມຄືນ ແລ້ວສະແກນອີກຄັ້ງ.", "هذا القرص لم يعد متصلًا. أعد توصيله وافحص مجددًا.", "הכונן הזה כבר אינו מחובר. חברו אותו שוב וסרקו פעם נוספת.", "این دیسک دیگر وصل نیست. دوباره وصلش کنید و دوباره اسکن بگیرید."],
    "storage.noAccess": ["Sift ຍັງອ່ານຕຳແໜ່ງນີ້ບໍ່ໄດ້.", "لا يستطيع Sift قراءة هذا الموقع بعد.", "Sift עדיין אינו יכול לקרוא מיקום זה.", "Sift هنوز نمی‌تواند این مکان را بخواند."],

    # --- Settings ----------------------------------------------------------
    "settings.title": ["ການຕັ້ງຄ່າ", "الإعدادات", "הגדרות", "تنظیمات"],
    "settings.group.scanScope": ["ຂອບເຂດການສະແກນ", "نطاق الفحص", "היקף הסריקה", "دامنهٔ اسکن"],
    "settings.group.thresholds": ["ເກນ", "الحدود", "ספים", "آستانه‌ها"],
    "settings.group.ignores": ["ລາຍການທີ່ປັດອອກ", "العناصر المتجاهَلة", "פריטים מוזנחים", "موارد نادیده‌گرفته‌شده"],
    "settings.group.confirmation": ["ການຢືນຢັນ", "التأكيد", "אישור", "تأیید"],
    "settings.group.appearance": ["ຮູບລັກສະນະ", "المظهر", "מראה", "ظاهر"],
    "settings.group.language": ["ພາສາ", "اللغة", "שפה", "زبان"],
    "settings.group.privacy": ["ຄວາມເປັນສ່ວນຕົວ", "الخصوصية", "פרטיות", "حریم خصوصی"],
    "settings.group.purchase": ["ການຊື້", "حالة الشراء", "מצב הרכישה", "وضعیت خرید"],
    "settings.group.logs": ["ການວິນິດໄສ", "التشخيص", "אבחון", "عیب‌یابی"],
    "settings.largeFileThreshold": ["ເກນໄຟລ໌ໃຫຍ່", "حد الملفات الكبيرة", "סף קבצים גדולים", "آستانهٔ فایل‌های بزرگ"],
    "settings.oldFileThreshold": ["ເກນໄຟລ໌ເກົ່າ", "حد الملفات القديمة", "סף קבצים ישנים", "آستانهٔ فایل‌های قدیمی"],
    "settings.days": ["%d ວັນ", "%d أيام", "%d ימים", "%d روز"],
    "settings.showHiddenFiles": ["ສະແດງໄຟລ໌ເຊື່ອງໃນຜົນການ", "عرض الملفات المخفية في النتائج", "הצגת קבצים נסתרים בתוצאות", "نمایش فایل‌های پنهان در نتایج"],
    "settings.userRules": ["ໃຊ້ໄຟລ໌ກົດການແບບກຳນົດເອງ", "استخدام ملف قواعد مخصص", "שימוש בקובץ כללים מותאם", "استفاده از پروندهٔ قواعد سفارشی"],
    "settings.userRulesDetail": ["ອ່ານ CleaningRules.json ຈາກໂຟນເດີຂໍ້ມູນຂອງແອັບ. ມີຜົນຕັ້ງແຕ່ການສະແກນຄັ້ງຕໍ່ໄປ.", "يقرأ CleaningRules.json من مجلد بيانات التطبيق. يُطبَّق من الفحص القادم.", "קורא את CleaningRules.json מתיקיית הנתונים של האפליקציה. חל מהסריקה הבאה.", "CleaningRules.json را از پوشهٔ دادهٔ برنامه می‌خواند. از اسکن بعدی اعمال می‌شود."],
    "settings.requireConfirmation": ["ຖາມຢືນຢັນກ່ອນລ້າງ", "طلب تأكيد قبل التنظيف", "לבקש אישור לפני ניקוי", "پیش از پاک‌سازی درخواست تأیید کن"],
    "settings.skipConfirmation": ["ຂ້າມການຢືນຢັນ", "تخطي التأكيد", "דילוג על האישור", "عبور از تأیید"],
    "settings.skipConfirmationWarning": ["Sift ຈະເລີ່ມລ້າງທັນທີທີ່ທ່ານກົດ. ລາຍການຍັງເຂົ້າຖັງຂີ້ເຫຍື້ອ ແຕ່ທ່ານຈະບໍ່ໄດ້ເຫັນລາຍການກ່ອນ. ລາຍການທີ່ໝາຍວ່າຕ້ອງກວດ ຈະສະແດງລາຍການສະເໝີ.", "سيبدأ Sift التنظيف فور النقر. ستذهب العناصر إلى المهملات، لكنك لن ترى القائمة أولًا. العناصر المحددة للمراجعة تعرض القائمة دائمًا.", "Sift יתחיל לנקות ברגע הלחיצה. הפריטים עדיין יגיעו לפח האשפה, אבל לא תראו את הרשימה קודם. פריטים המסומנים לבדיקה תמיד מציגים את הרשימה.", "Sift به‌محض کلیک پاک‌سازی را آغاز می‌کند. موارد همچنان به سطل بازیافت می‌روند، اما فهرست را پیش از آن نمی‌بینید. موارد نشان‌دار برای بررسی همیشه فهرست را نشان می‌دهند."],
    "settings.appearance.system": ["ຕາມລະບົບ", "كما في النظام", "כמו המערכת", "مطابق سیستم"],
    "settings.appearance.light": ["ສະຫວ່າງ", "فاتح", "בהיר", "روشن"],
    "settings.appearance.dark": ["ມືດ", "داكن", "כהה", "تاریک"],
    "settings.reduceMotion": ["ຫຼຸດຜົນກະທົບການເຄື່ອນໄຫວ", "تقليل الحركة", "הפחת תנועה", "کاهش حرکت"],
    "settings.privacyStatement": ["Sift ບໍ່ເກັບເນື້ອໃນໄຟລ໌, ຊື່ໄຟລ໌, ເສັ້ນທາງເຕັມ, ປະຫວັດການທ່ອງເວັບ, ການໃຊ້ແອັບ ຫຼື ຂໍ້ມູນບັນຊີ. ຜົນການສະແກນຢູ່ໃນເຄື່ອງນີ້ເທົ່ານັ້ນ ບໍ່ມີການສົ່ງຂຶ້ນເຊີຟ໌ເວີ.", "لا يجمع Sift محتويات الملفات، ولا أسماءها، ولا المسارات الكاملة، ولا سجل التصفح، ولا استخدام التطبيقات، ولا بيانات الحساب. تبقى نتائج الفحص على هذا Mac ولا يُرفع شيء.", "Sift אינו אוסף תכני קבצים, שמות קבצים, נתיבים מלאים, היסטוריית גלישה, שימוש באפליקציות או פרטי חשבון. תוצאות הסריקה נשארות ב-Mac הזה ושום דבר אינו מועלה.", "Sift محتوای فایل‌ها، نام فایل‌ها، مسیرهای کامل، سابقهٔ مرور، استفاده از برنامه‌ها یا اطلاعات حساب را جمع نمی‌کند. نتایج اسکن فقط روی همین مک می‌ماند و هیچ‌چیز بارگذاری نمی‌شود."],
    "settings.exportLogs": ["ສົ່ງອອກການວິນິດໄສ", "تصدير التشخيص", "ייצוא אבחון", "خروجی گرفتن از عیب‌یابی"],
    "settings.exportLogsDetail": ["ການວິນິດໄສບໍ່ມີຊື່ໄຟລ໌ ຫຼື ເສັ້ນທາງເຕັມ.", "التشخيص لا يحتوي على أسماء ملفات أو مسارات كاملة.", "האבחון אינו מכיל שמות קבצים או נתיבים מלאים.", "دادهٔ عیب‌یابی شامل نام فایل یا مسیر کامل نیست."],
    "settings.clearHistory": ["ລ້າງປະຫວັດການສະແກນ", "مسح سجل الفحوصات", "מחיקת היסטוריית הסריקות", "پاک کردن تاریخچهٔ اسکن‌ها"],
    "settings.deleteReports": ["ລຶບລາຍງານທີ່ບັນທຶກໄວ້", "حذف التقارير المحفوظة", "מחיקת הדוחות השמורים", "حذف گزارش‌های ذخیره‌شده"],
    "settings.deleteReportsConfirm": ["ລຶບລາຍງານ PDF ທີ່ບັນທຶກໄວ້ທັງໝົດ? ເຮັດແລ້ວຍ້ອນກັບບໍ່ໄດ້.", "حذف جميع تقارير PDF المحفوظة؟ لا يمكن التراجع عن هذا الإجراء.", "למחוק את כל הדוחות ב-PDF השמורים? פעולה זו בלתי הפיכה.", "حذف همهٔ گزارش‌های PDF ذخیره‌شده؟ این اقدام بازگشت‌پذیر نیست."],
    "settings.resetDefaults": ["ຄືນຄ່າເລີ່ມຕົ້ນ", "استعادة الإعدادات الافتراضية", "שחזור ברירות המחדל", "بازگردانی پیش‌فرض‌ها"],

    # --- Purchase ----------------------------------------------------------
    "purchase.title": ["ປົດລັອກ Sift", "فتح Sift", "שחרור Sift", "بازکردن Sift"],
    "purchase.priceLine": ["4.99$ ຈ່າຍຄັ້ງດຽວ, ໃຊ້ໄດ້ຕະຫຼອດ, ບໍ່ມີການສະໝັກສະມາຊິກ", "‏4.99 دولار مرة واحدة، لك للأبد، بدون اشتراك", "‏4.99$ פעם אחת, לנצח, בלי מינוי", "‏۴٫۹۹ دلار یک‌بار، برای همیشه، بدون اشتراک"],
    "purchase.updatesPromise": ["ລວມການອັບເດດເວີຊັນໃຫຍ່ໃນອະນາຄົດ.", "يشمل التحديثات الكبرى القادمة.", "כולל עדכונים מרכזיים עתידיים.", "شامل به‌روزرسانی‌های بزرگ آینده."],
    "purchase.freeTier.scan": ["ສະແກນທົ່ວ Mac", "فحص جهاز Mac بالكامل", "סריקת כל ה-Mac", "اسکن کل مک"],
    "purchase.freeTier.explain": ["ເຫັນທຸກລາຍການ ແຫຼ່ງທີ່ມາ ແລະ ລະດັບຄວາມສ່ຽງ", "رؤية كل عنصر ومصدره ومخاطره", "לראות כל פריט, את מקורו ואת הסיכון שלו", "دیدن هر مورد، منبع و ریسک آن"],
    "purchase.freeTier.estimate": ["ເຫັນວ່າສາມາດສ້າງພື້ນທີ່ໄດ້ຫຼາຍປານໃດ", "معرفة مقدار المساحة التي يمكن تحريرها", "לראות כמה שטח אפשר לפנות", "دیدن اینکه چقدر فضا می‌توانید آزاد کنید"],
    "purchase.freeTier.storage": ["ວິເຄາະພື້ນທີ່ຈັດເກັບຕາມປະເພດ ແລະ ໂຟນເດີ", "تحليل التخزين حسب النوع والمجلد", "ניתוח האחסון לפי סוג ותיקייה", "تحلیل حافظه بر اساس نوع و پوشه"],
    "purchase.paidTierTitle": ["ສິ່ງທີ່ໄດ້ເພີ່ມເມື່ອປົດລັອກ", "ما يضيفه الفتح", "מה השחרור מוסיף", "آنچه بازکردن می‌افزاید"],
    "purchase.paidTier.clean": ["ຍ້າຍແຄຊ໌, ໄຟລ໌ບັນທຶກ ແລະ ໂປຣແກຣມຕິດຕັ້ງໄປຖັງຂີ້ເຫຍື້ອ", "نقل الذاكرات المؤقتة والسجلات وبرامج التثبيت إلى المهملات", "העברת מטמונים, יומנים ומתקינים אל פח האשפה", "انتقال حافظه‌های نهانی، گزارش‌ها و نصب‌کننده‌ها به سطل بازیافت"],
    "purchase.paidTier.uninstall": ["ຖອນການຕິດຕັ້ງແອັບ ພ້ອມໄຟລ໌ທີ່ກ່ຽວຂ້ອງ", "إزالة التطبيقات مع ملفاتها المرتبطة", "הסרת אפליקציות יחד עם הקבצים הקשורים", "حذف برنامه‌ها همراه با فایل‌های مرتبطشان"],
    "purchase.paidTier.files": ["ລ້າງໄຟລ໌ໃຫຍ່, ເກົ່າ ແລະ ຊ້ຳ", "تنظيف الملفات الكبيرة والقديمة والمكررة", "ניקוי קבצים גדולים, ישנים ומשוכפלים", "پاک‌سازی فایل‌های بزرگ، قدیمی و تکراری"],
    "purchase.paidTier.report": ["ລາຍງານການລ້າງເຕັມຮູບແບບ ແລະ ການສົ່ງອອກ PDF", "تقارير تنظيف كاملة وتصدير PDF", "דוחות ניקוי מלאים וייצוא PDF", "گزارش‌های کامل پاک‌سازی و خروجی PDF"],
    "purchase.activateLicense": ["ໃສ່ລະຫັດໃບອະນຸຍາດ", "أدخل مفتاح الترخيص", "הזן את מפתח הרישיון", "کلید مجوز را وارد کنید"],
    "purchase.restore": ["ກູ້ຄືນການຊື້", "استعادة الشراء", "שחזור הרכישה", "بازیابی خرید"],
    "purchase.restored": ["ກູ້ຄືນການຊື້ແລ້ວ. ຟັງຊັນລ້າງເປີດແລ້ວ.", "استُعيدت عملية الشراء. التنظيف مفتوح.", "הרכישה שוחזרה. הניקוי פתוח.", "خرید بازیابی شد. پاک‌سازی باز شد."],
    "purchase.activated": ["ເປີດໃບອະນຸຍາດແລ້ວ. ຂອບໃຈ!", "تم تفعيل الترخيص. شكرًا!", "הרישיון הופעל. תודה!", "مجوز فعال شد. سپاسگزاریم!"],
    "purchase.failed": ["ເຮັດບໍ່ສຳເລັດ. ລອງໃໝ່ອີກຄັ້ງ.", "لم نتمكن من إكمال ذلك. حاول مجددًا.", "לא הצלחנו להשלים זאת. נסו שוב.", "نتوانستیم این را کامل کنیم. دوباره تلاش کنید."],
    "purchase.networkUnavailable": ["ເຊື່ອມຕໍ່ບໍລິການຊື້ບໍ່ໄດ້. ໃບອະນຸຍາດຂອງທ່ານຍັງໃຊ້ແບບອອຟໄລນ໌ໄດ້ໃນຕອນນີ້.", "تعذّر الوصول إلى خدمة الشراء. تظل ترخيصك صالحًا دون اتصال في الوقت الحالي.", "לא ניתן היה להתחבר לשירות הרכישות. הרישיון שלכם עדיין עובד ללא חיבור בינתיים.", "به سرویس خرید دسترسی ممکن نشد. مجوز شما فعلاً همچنان آفلاین کار می‌کند."],
    "purchase.licenseRequired": ["ປົດລັອກ Sift ເພື່ອລ້າງ", "افتح Sift للتنظيف", "שחררו את Sift לניקוי", "برای پاک‌سازی Sift را باز کنید"],
    "purchase.licenseRequiredDetail": ["ການສະແກນ, ການວິເຄາະ ແລະ ການເບິ່ງຕົວຢ່າງ ຟຣີສະເໝີ. ການລ້າງ ແລະ ຖອນການຕິດຕັ້ງ ຕ້ອງຊື້ຄັ້ງດຽວ.", "الفحص والتحليل والمعاينة مجانية دائمًا. التنظيف والإزالة يتطلبان شراءً لمرة واحدة.", "סריקה, ניתוח ותצוגה מקדימה נשארים חינם. ניקוי והסרה דורשים רכישה חד-פעמית.", "اسکن، تحلیل و پیش‌نمایش همیشه رایگان‌اند. پاک‌سازی و حذف به خرید یک‌باره نیاز دارند."],
    "purchase.offlineGrace": ["ໄລຍະໃຫ້ອະໄພແບບອອຟໄລນ໌: ຍັງເຫຼືອ %d ວັນ", "فترة السماح دون اتصال: بقي %d يومًا", "תקופת חסד ללא חיבור: נותרו %d ימים", "مهلت آفلاین: %d روز مانده"],
    "purchase.status.purchased": ["ຊື້ແລ້ວ", "تم الشراء", "נרכש", "خریده شده"],
    "purchase.status.free": ["ເວີຊັນຟຣີ", "النسخة المجانية", "גרסה חינמית", "نسخهٔ رایگان"],
    "nav.account": ["ບັນຊີ", "الحساب", "חשבון", "حساب"],
    "account.activatedAt": ["ວັນທີເປີດໃຊ້ງານ", "تاريخ التنشيط", "תאריך ההפעלה", "تاریخ فعال‌سازی"],
    "account.licenseKey": ["ກະແຈໃບອະນຸຍາດ", "مفتاح الترخيص", "מפתח רישיון", "کلید مجوز"],
    # --- Report ------------------------------------------------------------
    "report.title": ["ລາຍງານການລ້າງ", "تقرير التنظيف", "דוח ניקוי", "گزارش پاک‌سازی"],
    "report.generatedAt": ["ສ້າງເມື່ອ %@", "أُنشئ في %@", "נוצר ב-%@", "ایجادشده در %@"],
    "report.appVersion": ["Sift %@ ໃນ macOS %@", "Sift %@ على macOS %@", "Sift %@ על macOS %@", "Sift %@ روی مک‌او‌اس %@"],
    "report.scope": ["ສິ່ງທີ່ຖືກສະແກນ", "ما تم فحصه", "מה נסרק", "چه چیزی اسکن شد"],
    "report.scopeDetail": ["%d ຕຳແໜ່ງ, ກວດ %d ໄຟລ໌", "%d مواقع، %d ملفات تم فحصها", "%d מיקומים, %d קבצים נבדקו", "%d مکان، بررسی %d فایل"],
    "report.categories": ["ປະເພດທີ່ຈັດການ", "الفئات التي عولجت", "הקטגוריות שטופלו", "دسته‌های مورد رسیدگی"],
    "report.status": ["ສະຖານະ", "الحالة", "מצב", "وضعیت"],
    "report.status.moved": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອແລ້ວ", "نُقل إلى المهملات", "הועבר אל פח האשפה", "به سطل بازیافت منتقل شد"],
    "report.status.skipped": ["ຂ້າມແລ້ວ", "تخطي", "דולג", "رد شده"],
    "report.status.failed": ["ບໍ່ສຳເລັດ", "لم يكتمل", "לא הושלם", "ناتمام"],
    "report.moved": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອແລ້ວ", "نُقل إلى المهملات", "הועבר אל פח האשפה", "به سطل بازیافت منتقل شد"],
    "report.movedDetail": ["%d ລາຍການ, %@", "%d عناصر، %@", "%d פריטים, %@", "%d مورد، %@"],
    "report.released": ["ພື້ນທີ່ສ້າງໄດ້", "المساحة المُحرَّرة", "השטח ששוחרר", "فضای آزادشده"],
    "report.skipped": ["ຂ້າມແລ້ວ", "المتخطاة", "שדולגו", "ردشده‌ها"],
    "report.skippedDetail": ["ຂ້າມ %d ລາຍການແລ້ວ, ສະແດງໃຫ້ເຫັນ 20 ອັນທຳອິດ.", "تم تخطي %d عناصر. تُعرض الأولى 20.", "דולגו %d פריטים. מוצגים 20 הראשונים.", "%d مورد رد شد. ۲۰ مورد نخست نشان داده می‌شود."],
    "report.failed": ["ບໍ່ສຳເລັດ", "لم تكتمل", "שלא הושלמו", "ناتمام‌ها"],
    "report.failedDetail": ["%d ລາຍການ, ເບິ່ງລາຍລະອຽດຂ້າງລຸ່ມ", "%d عناصر، انظر التفاصيل أدناه", "%d פריטים, ראו את הפרטים להלן", "%d مورد، جزئیات را در پایین ببینید"],
    "report.privacyNote": ["ລາຍງານນີ້ລາຍການປະເພດ ແລະ ຂະໜາດເທົ່ານັ້ນ. ບໍ່ມີຊື່ໄຟລ໌, ເສັ້ນທາງ ຫຼື ເນື້ອໃນ.", "يسرد هذا التقرير الفئات والأحجام فقط. لا يحتوي على أسماء ملفات أو مسارات أو محتويات.", "הדוח הזה מפרט קטגוריות וגדלים בלבד. הוא אינו מכיל שמות קבצים, נתיבים או תוכן.", "این گزارش فقط دسته‌ها و اندازه‌ها را فهرست می‌کند. شامل نام فایل، مسیر یا محتوا نیست."],
    "report.exportFailed": ["ບັນທຶກລາຍງານບໍ່ສຳເລັດ. ສຳເນົາໃນເຄື່ອງຍັງຢູ່ ຈຶ່ງລອງໃໝ່ໄດ້.", "تعذّر حفظ التقرير. تبقى النسخة المحلية متاحة لإعادة المحاولة.", "הדוח לא נשמר. העותק המקומי נותר זמין לניסיון חוזר.", "ذخیرهٔ گزارش ممکن نشد. نسخهٔ محلی هنوز هست؛ دوباره تلاش کنید."],

    # --- Permissions -------------------------------------------------------
    "permission.fullDiskAccess": ["ສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ", "الوصول الكامل إلى القرص", "גישה מלאה לכונן", "دسترسی کامل به دیسک"],
    "permission.fullDiskAccessDetail": ["Sift ສະແກນແຄຊ໌ ແລະ ໄຟລ໌ບັນທຶກໄດ້ໂດຍບໍ່ຕ້ອງສິດນີ້. ເມື່ອອະນຸຍາດແລ້ວ ຈະອ່ານໄຟລ໌ບັນທຶກລະບົບ ແລະ ໂຟນເດີສະໜັບສະໜູນແອັບໄດ້ນຳ.", "يفحص Sift الذاكرات المؤقتة والسجلات بدون ذلك. بمنح الوصول الكامل إلى القرص، يقرأ أيضًا سجلات النظام ومجلدات دعم التطبيقات.", "Sift סורק מטמונים ויומנים גם בלי זה. מתן גישה מלאה לכונן מאפשר לו לקרוא גם יומני מערכת ותיקיות תמיכה של אפליקציות.", "Sift بدون این مجوز هم حافظه‌های نهانی و گزارش‌ها را اسکن می‌کند. با دادن دسترسی کامل به دیسک، گزارش‌های سیستم و پوشه‌های پشتیبانی برنامه‌ها را هم می‌خواند."],
    "permission.partialAccess": ["ບາງຕຳແໜ່ງອ່ານບໍ່ໄດ້", "تعذّرت قراءة بعض المواقع", "חלק מהמיקומים לא ניתנים לקריאה", "خواندن برخی مکان‌ها ممکن نشد"],
    "permission.openSettings": ["ເປີດການຕັ້ງຄ່າລະບົບ", "افتح إعدادات النظام", "פתח את הגדרות המערכת", "باز کردن تنظیمات سیستم"],
    "permission.grantLater": ["ສືບຕໍ່ໂດຍບໍ່ຕ້ອງສິດ", "المتابعة بدون ذلك", "להמשיך בלי", "ادامه بدون آن"],

    "settings.diagnostics.scannerCore": ["ແກນການສະແກນ", "نواة الفحص", "ליבת הסריקה", "هستهٔ اسکن"],
    "settings.diagnostics.version": ["ເວີຊັນ", "الإصدار", "גרסה", "نسخه"],
    "settings.diagnostics.macOS": ["macOS", "macOS", "macOS", "macOS"],

    # --- Common ------------------------------------------------------------
    "common.done": ["ສຳເລັດ", "تم", "בוצע", "انجام شد"],
    "common.close": ["ປິດ", "إغلاق", "סגור", "بستن"],
    "common.remove": ["ເອົາອອກ", "إزالة", "הסר", "حذف"],
    "common.unknownError": ["ບໍ່ສຳເລັດ. ລອງໃໝ່ອີກຄັ້ງ.", "لم ينجح ذلك. حاول مجددًا.", "זה לא עבד. נסו שוב.", "این کار انجام نشد. دوباره تلاش کنید."],
    "common.fileCount": ["%d ໄຟລ໌", "%d ملفات", "%d קבצים", "%d فایل"],
    "common.itemCount": ["%d ລາຍການ", "%d عناصر", "%d פריטים", "%d مورد"],
    "common.notAvailable": ["ໃຊ້ບໍ່ໄດ້", "غير متاح", "לא זמין", "در دسترس نیست"],
    "common.loadMore": ["ໂຫຼດເພີ່ມ", "تحميل المزيد", "טען עוד", "بارگیری بیشتر"],
    "common.retry": ["ລອງໃໝ່", "أعد المحاولة", "נסה שוב", "دوباره تلاش کنید"],
    "common.of": ["%@ ຈາກ %@", "%@ من %@", "%@ מתוך %@", "%@ از %@"],
    "common.size": ["ຂະໜາດ", "الحجم", "גודל", "اندازه"],
    "common.risk": ["ລະດັບຄວາມສ່ຽງ", "المخاطرة", "סיכון", "ریسک"],
    "common.quitApp": ["ອອກຈາກແອັບ", "إنهاء التطبيق", "צא מהאפליקציה", "خروج از برنامه"],
    "common.loading": ["ກຳລັງໂຫຼດ…", "جارٍ التحميل…", "טוען…", "در حال بارگیری…"],
    "common.sortBy": ["ຈັດລຳດັບຕາມ", "الترتيب حسب", "מיון לפי", "مرتب‌سازی بر اساس"],
    # --- Redesigned navigation, overview, scan, apps and storage -----------
    "nav.scan": ["ສະແກນ", "فحص", "סריקה", "اسکن"],
    "nav.apps": ["ແອັບ", "تطبيقات", "אפליקציות", "برنامه‌ها"],

    "overview.scanScope": ["ສິ່ງທີ່ການສະແກນຄຸມ", "ما يشمله الفحص", "מה הסריקה מכסה", "اسکن چه چیزی را در بر می‌گیرد"],
    "overview.status": ["%@", "%@", "%@", "%@"],
    "overview.reclaimable.title": ["ປອດໄພທີ່ຈະສ້າງຄືນ", "أمن للتحرير", "בטוח לפינוי", "امن برای آزادسازی"],
    "overview.reclaimable.breakdown": ["%@ ປອດໄພ, %@ ຕ້ອງທ່ານຢືນຢັນ", "%@ آمن و %@ يتطلب تأكيدك", "%@ בטוח, %@ דורש את אישורכם", "%@ امن است، %@ نیاز به تأیید شما دارد"],
    "overview.reclaimable.meta": ["%d ປະເພດ, %d ລາຍການ", "%d فئات, %d عناصر", "%d קטגוריות, %d פריטים", "%d دسته, %d مورد"],
    "overview.ready": ["ພ້ອມສະແກນແລ້ວ", "جاهز للفحص", "מוכן לסריקה", "آمادهٔ اسکن"],
    "overview.noResults": ["ສະແກນກ່ອນ ເພື່ອເຫັນວ່າສາມາດສ້າງພື້ນທີ່ໄດ້ປອດໄພປານໃດ.", "شغّل فحصًا لترى ما يمكن تحريره بأمان.", "הריצו סריקה כדי לראות מה אפשר לפנות בבטחה.", "اسکنی اجرا کنید تا ببینید چه چیزهایی می‌توانند با اطمینان آزاد شوند."],
    "overview.viewProgress": ["ເບິ່ງຄວາມຄືບໜ້າການສະແກນ", "عرض تقدم الفحص", "הצגת התקדמות הסריקה", "دیدن پیشرفت اسکن"],
    "overview.noCleanup": ["ຍັງບໍ່ມີການລ້າງ", "لا تنظيف بعد", "עדיין אין ניקוי", "هنوز پاک‌سازی نبوده"],
    "overview.cleanupHistoryHint": ["ປະຫວັດການລ້າງຈະສະແດງຢູ່ນີ້.", "سيظهر سجل التنظيفات هنا.", "היסטוריית הניקויים תופיע כאן.", "تاریخچهٔ پاک‌سازی‌ها اینجا دیده می‌شود."],
    "overview.viewResults": ["ເບິ່ງຜົນການສະແກນ", "عرض النتائج", "הצגת תוצאות", "دیدن نتایج اسکن"],
    "overview.localOnly": ["ການສະແກນແລ່ວຢູ່ໃນເຄື່ອງນີ້ທັງໝົດ.", "يجري الفحص بالكامل على هذا Mac.", "הסריקה מתבצעת כולה על ה-Mac הזה.", "اسکن کاملاً روی همین مک اجرا می‌شود."],
    "overview.diskUsageDetail": ["ຫວ່າງ %@, ລວມ %@", "%@ حر, %@ إجمالًا", "%@ פנוי, %@ בסך הכול", "%@ آزاد, در مجموع %@"],
    "overview.lastCleanupTitle": ["ສ້າງຄືນໄດ້ຈາກການລ້າງຄັ້ງສຸດທ້າຍ", "المُحرَّر في آخر تنظيف", "ששוחרר בניקוי האחרון", "آزادشده در آخرین پاک‌سازی"],
    "overview.lastCleanupMeta": ["%@ · %d ລາຍການ · ໄປຖັງຂີ້ເຫຍື້ອ", "%@ · %d عناصر · إلى المهملات", "%@ · %d פריטים · אל פח האשפה", "%@ · %d مورد · به سطل بازیافت"],
    "overview.selectedSummary": ["ເລືອກແລ້ວ %d ລາຍການ, %@", "تم تحديد %d, %@", "נבחרו %d, %@", "%d مورد انتخاب شد, %@"],
    "overview.moreItems": ["ຍັງມີ %d ລາຍການຂະໜາດນ້ອຍ, ລວມ %@", "%d عناصر أصغر, %@ إجمالًا", "עוד %d פריטים קטנים, %@ בסך הכול", "%d مورد کوچک‌تر دیگر, در مجموع %@"],
    "overview.showAll": ["ສະແດງທັງໝົດ", "عرض الكل", "הצג הכול", "نمایش همه"],
    "overview.historyLocal": ["ປະຫວັດຢູ່ໃນເຄື່ອງນີ້ເທົ່ານັ້ນ; ບໍ່ຊິງ ແລະ ບໍ່ສົ່ງຂຶ້ນເຊີຟ໌.", "يبقى السجل على هذا Mac؛ لا تتم مزامنته ولا رفعه.", "ההיסטוריה נשארת ב-Mac הזה; שום דבר אינו מסונכרן או מועלה.", "تاریخچه فقط روی همین مک می‌ماند؛ هیچ‌چیز همگام‌سازی یا بارگذاری نمی‌شود."],
    "overview.activityScan": ["ສະແກນສຳເລັດ, %d ລາຍການ", "اكتمل الفحص، %d عناصر", "הסריקה הושלמה, %d פריטים", "اسکن کامل شد، %d مورد"],
    "overview.activityUninstall": ["ຄຳແນະນຳຖອນການຕິດຕັ້ງ, %d ແອັບທີ່ບໍ່ໄດ້ເປີດດົນນານ", "اقتراح إزالة, %d تطبيقات لم تُفتح مؤخرًا", "עצת הסרה, %d אפליקציות שלא נפתחו זמן רב", "پیشنهاد حذف, %d برنامه که مدتی است باز نشده"],
    "overview.activityStorage": ["ວິເຄາະພື້ນທີ່ຈັດເກັບແລ້ວ, ວັດແທກໄດ້ %@", "تم تحليل التخزين, قياس %@", "האחסון נותח, נמדדו %@", "حافظه تحلیل شد, %@ اندازه‌گیری شد"],
    "scan.filter.all": ["ທັງໝົດ", "الكل", "הכול", "همه"],
    "scan.filter.junk": ["ຂີ້ເຫຍື້ອ", "غير مرغوب", "זבל", "زائد"],
    "scan.filter.large": ["ໃຫຍ່", "كبيرة", "גדולים", "بزرگ"],
    "scan.filter.old": ["ເກົ່າ", "قديمة", "ישנים", "قدیمی"],
    "scan.filter.duplicates": ["ຊ້ຳ", "مكررات", "כפילויות", "تکراری"],
    "scan.rescan": ["ສະແກນຄືນໃໝ່", "فحص مجددًا", "סרוק שוב", "اسکن دوباره"],
    "scan.headerStatus": ["ຜົນການຈາກ %@ · %d ລາຍການ", "نتائج من %@ · %d عناصر", "תוצאות מ-%@ · %d פריטים", "نتایج از %@ · %d مورد"],
    "scan.results.safeGroup": ["ລ້າງໄດ້ຢ່າງປອດໄພ", "يمكن تنظيفه بأمان", "ניתן לניקוי בטוח", "قابل پاک‌سازی امن"],
    "scan.results.reviewGroup": ["ຕ້ອງການທ່ານຢືນຢັນ", "يتطلب تأكيدك", "דורש את אישורכם", "نیازمند تأیید شما"],
    "scan.results.protectedGroup": ["ປ້ອງກັນໄວ້", "محمي", "מוגן", "محافظت‌شده"],
    "scan.results.defaultSelected": ["ເລືອກໄວ້ໂດຍຄ່າເລີ່ມຕົ້ນ", "محدد افتراضيًا", "מסומן כברירת מחדל", "به‌طور پیش‌فرض انتخاب شده"],
    "scan.results.reviewHint": ["ຢືນຢັນແຕ່ລະລາຍການກ່ອນລ້າງ", "أكّد كل عنصر قبل التنظيف", "אשרו כל פריט לפני הניקוי", "پیش از پاک‌سازی هر مورد را تأیید کنید"],
    "scan.results.cleanTitle": ["ການລ້າງຄັ້ງນີ້", "هذا التنظيف", "הניקוי הזה", "این پاک‌سازی"],
    "scan.results.cleanButton": ["ລ້າງ %d ລາຍການ", "تنظيف %d عناصر", "נקה %d פריטים", "پاک‌سازی %d مورد"],
    "scan.results.trashHint": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ; ກູ້ຄືນໄດ້ຈົນກວ່າຈະລ້າງຖັງ.", "ينتقل إلى المهملات؛ يمكن استعادته حتى تفرغها.", "מועבר אל פח האשפה; אפשר לשחזר עד שתרוקנו אותו.", "به سطل بازیافت منتقل می‌شود؛ تا خالی کردنش قابل بازیابی است."],
    "scan.results.protectedHint": ["ໄຟລ໌ລະບົບ ແລະ ຕຳແໜ່ງທີ່ປ້ອງກັນໄວ້ຖືກຂ້າມໂດຍອັດຕະໂນມັດ", "ملفات النظام والمواقع المحمية تُتخطى تلقائيًا", "קבצי מערכת ומיקומים מוגנים דולגים אוטומטית", "فایل‌های سیستم و مکان‌های محافظت‌شده به‌طور خودکار رد می‌شوند"],
    "scan.results.reportHint": ["ກູ້ຄືນຈາກຖັງຂີ້ເຫຍື້ອ ຫຼື ສົ່ງອອກລາຍງານການລ້າງ.", "استعد من المهملات أو صدّر تقرير تنظيف.", "שחזרו מפח האשפה או ייצאו דוח ניקוי.", "از سطل بازیافت بازگردانید یا گزارش پاک‌سازی بگیرید."],
    "scan.results.sortSize": ["ຕາມຂະໜາດ", "حسب الحجم", "לפי גודל", "بر اساس اندازه"],
    "scan.results.sortName": ["ຕາມຊື່", "حسب الاسم", "לפי שם", "بر اساس نام"],
    "scan.results.sortModified": ["ຕາມວັນທີແກ້ໄຂ", "حسب تاريخ التعديل", "לפי תאריך שינוי", "بر اساس تاریخ تغییر"],
    "scan.results.categoryTotals": ["ຕາມປະເພດ: %@", "حسب الفئة: %@", "לפי קטגוריה: %@", "بر اساس دسته: %@"],
    "scan.running.status": ["ກຳລັງສະແກນ, ຂັ້ນຕອນ %d ຈາກ %d", "جارٍ الفحص, الخطوة %d من %d", "סורק, שלב %d מתוך %d", "در حال اسکن, گام %d از %d"],
    "scan.running.step": ["ຂັ້ນຕອນ %d ຈາກ %d", "الخطوة %d من %d", "שלב %d מתוך %d", "گام %d از %d"],
    "scan.running.target": ["ເປົ້າໝາຍປັດຈຸບັນ", "الهدف الحالي", "היעד הנוכחי", "هدف فعلی"],
    "scan.running.walked": ["ຜ່ານແລ້ວ %@ ໄຟລ໌", "تم استعراض %@ ملفًا", "עברו %@ קבצים", "%@ فایل پیمایش شد"],
    "scan.running.found": ["ພົບ %@", "تم العثور على %@", "נמצאו %@", "%@ یافت شد"],
    "scan.running.elapsed": ["ເວລາທີ່ໃຊ້", "الوقت المنقضي", "זמן שחלף", "زمان سپری‌شده"],
    "scan.running.phase": ["ຂັ້ນຕອນປັດຈຸບັນ", "المرحلة الحالية", "השלב הנוכחי", "مرحلهٔ فعلی"],
    "scan.running.readOnly": ["ອ່ານຊື່, ຂະໜາດ ແລະ ວັນທີແກ້ໄຂເທົ່ານັ້ນ. ບໍ່ເປີດເນື້ອໃນ ແລະ ບໍ່ສົ່ງຂໍ້ມູນ.", "يقرأ الأسماء والأحجام وتواريخ التعديل فقط. لا يفتح الملفات ولا يرفع بيانات.", "קורא רק שמות, גדלים ותאריכי שינוי. אינו פותח קבצים ואינו שולח נתונים.", "فقط نام‌ها، اندازه‌ها و تاریخ‌های تغییر را می‌خواند. فایلی را باز نمی‌کند و داده‌ای نمی‌فرستد."],
    "scan.running.categories": ["ພົບຕາມປະເພດ", "المعثور عليه حسب الفئة", "נמצא לפי קטגוריה", "یافته‌ها بر اساس دسته"],
    "scan.running.categoryCount": ["%d ປະເພດ", "%d فئات", "%d קטגוריות", "%d دسته"],
    "scan.running.waiting": ["ກຳລັງລໍຖ້າ", "بانتظار", "ממתין", "در انتظار"],
    "scan.running.finding": ["ກຳລັງພົບ", "يكتشف", "מוצא", "در حال یافتن"],

    "apps.status": ["ຕິດຕັ້ງ %d · %d ອັນບໍ່ໄດ້ເປີດ 6 ເດືອນ", "%d مثبّتة · %d لم تُفتح منذ 6 أشهر", "%d מותקנות · %d לא נפתחו 6 חודשים", "%d نصب‌شده · %d شش ماه است باز نشده"],
    "apps.listTitle": ["ແອັບພລິເຄຊັນ", "التطبيقات", "אפליקציות", "برنامه‌ها"],
    "apps.sortSummary": ["ຈັດລຳດັບຕາມຂະໜາດ, ລວມ %@", "مرتّبة حسب الحجم, %@ إجمالًا", "ממוינות לפי גודל, %@ בסך הכול", "مرتب بر اساس اندازه, در مجموع %@"],
    "apps.reclaimable": ["ສາມາດສ້າງຄືນ", "يمكن تحريره", "ניתן לפינוי", "قابل آزادسازی"],
    "apps.appAndRelated": ["ແອັບ %@, ໄຟລ໌ທີ່ກ່ຽວຂ້ອງ %@", "التطبيق %@, ملفات مرتبطة %@", "אפליקציה %@, קבצים קשורים %@", "برنامه %@, فایل‌های مرتبط %@"],
    "apps.relatedWillRemove": ["ໄຟລ໌ທີ່ກ່ຽວຂ້ອງທີ່ຈະລຶບ", "ملفات مرتبطة للإزالة", "קבצים קשורים להסרה", "فایل‌های مرتبط برای حذف"],
    "apps.uninstallAndClean": ["ຖອນການຕິດຕັ້ງ ແລະ ລ້າງ %@", "إزالة وتنظيف %@", "הסרה וניקוי של %@", "حذف و پاک‌سازی %@"],
    "apps.restoreHint": ["ກູ້ຄືນຈາກຖັງຂີ້ເຫຍື້ອໄດ້ ຈົນກວ່າຈະລ້າງຖັງ", "قابل للاستعادة من المهملات حتى تفرغها", "ניתן לשחזר מפח האשפה עד שתרוקנו אותו", "تا خالی کردن سطل بازیافت قابل بازیابی است"],
    "apps.footer": ["ສະແດງແອັບທີ່ໃຫຍ່ກວ່າ 200 MB · ລວມ %d ອັນ", "عرض التطبيقات فوق 200 ميغابايت · %d إجمالًا", "מציג אפליקציות מעל 200 MB · %d בסך הכול", "نمایش برنامه‌های بالای ۲۰۰ مگابایت · در مجموع %d"],
    "apps.lastOpened": ["ເປີດຄັ້ງສຸດທ້າຍ %@", "آخر فتح %@", "נפתח לאחרונה %@", "آخرین بازشدن %@"],
    "apps.neverOpened": ["ບໍ່ເຄີຍເປີດ", "لم يُفتح أبدًا", "מעולם לא נפתח", "هرگز باز نشده"],

    "storage.startTitle": ["ເບິ່ງວ່າຫຍັງກິນພື້ນທີ່ດິສກ໌", "انظر ما الذي يشغل القرص", "ראו מה תופס את הכונן", "ببینید چه چیزی دیسک را اشغال کرده"],
    "storage.status": ["%@, ໃຊ້ໄປ %@ ຈາກ %@", "%@, %@ مستخدم من %@", "%@, %@ בשימוש מתוך %@", "%@, %@ از %@ استفاده شده"],
    "storage.spaceDistribution": ["ການແຈກຢາຍພື້ນທີ່", "توزيع المساحة", "חלוקת השטח", "توزیع فضا"],
    "storage.categoryDetail": ["ລາຍລະອຽດຕາມປະເພດ", "تفصيل حسب الفئة", "פירוט לפי קטגוריה", "جزئیات بر اساس دسته"],
    "storage.usageShare": ["ສັດສ່ວນການໃຊ້", "الاستخدام", "ניצול", "میزان استفاده"],
    "storage.availableSpace": ["ຫວ່າງ", "متاح", "זמין", "در دسترس"],
    "storage.localNote": ["ວັດແທກຢູ່ເຄື່ອງນີ້. ບໍ່ສົ່ງຂຶ້ນເຊີຟ໌ ຫຼື ເຊື່ອມຕໍ່ອອນລາຍ.", "قِيس على هذا Mac. لا يُرفع ولا يُرسل عبر الشبكة.", "נמדד על Mac זה. שום דבר אינו מועלה או נשלח לרשת.", "روی همین مک اندازه‌گیری شده. هیچ‌چیز بارگذاری یا به شبکه ارسال نمی‌شود."],
    "storage.suggestionTitle": ["ຄຳແນະນຳ", "اقتراح", "הצעה", "پیشنهاد"],
    "storage.cleanableHeading": ["%@ ລ້າງໄດ້", "%@ يمكن تنظيفها", "%@ ניתנים לניקוי", "%@ قابل پاک‌سازی است"],
    "storage.suggestionDetail": ["ເລີ່ມຈາກແຄຊ໌ ແລະ ໂປຣແກຣມຕິດຕັ້ງເກົ່າ ແລ້ວສະແກນຄືນເພື່ອຢືນຢັນ.", "ابدأ بالذاكرات المؤقتة وبرامج التثبيت القديمة، ثم افحص مجددًا للتأكيد.", "התחילו במטמונים ובמתקינים ישנים ואז סרקו שוב לאישוש.", "با حافظه‌های نهانی و نصب‌کننده‌های قدیمی شروع کنید و سپس برای اطمینان دوباره اسکن بگیرید."],
    "storage.goClean": ["ໄປລ້າງ", "اذهب للتنظيف", "עבור לניקוי", "برو به پاک‌سازی"],

    "settings.headerStatus": ["ການຕັ້ງຄ່າ, Sift %@", "الإعدادات, Sift %@", "הגדרות, Sift %@", "تنظیمات, Sift %@"],
    "language.search": ["ຄົ້ນຫາພາສາ", "البحث عن لغة", "חיפוש שפות", "جستجوی زبان"],
    "language.noResults": ["ບໍ່ມີພາສາທີ່ກົງກັນ", "لا توجد لغة مطابقة", "אין שפה מתאימה", "زبانی مطابق یافت نشد"],

    # --- Trash and snapshots ---
    "trash.empty.action": ["ລຶບຖັງຂີ້ເຫຍື້ອ", "إفراغ سلة المهملات", "ריקון סל האשפה", "خالی کردن سطل زباله"],
    "trash.empty.message": ["ຈະລຶບ %@ ຢ່າງຖາວອນ ແລະ ບໍ່ສາມາດກູ້ຄືນໄດ້", "سيتم حذف %@ نهائيًا. لا يمكن التراجع عن ذلك.", "הפריט %@ יימחק לצמיתות. לא ניתן לבטל פעולה זו.", "%@ برای همیشه حذف می‌شود. این کار قابل بازگشت نیست."],
    "diagnostics.snapshots.openTimeMachine": ["ເປີດ Time Machine", "فتح Time Machine", "פתיחת Time Machine", "باز کردن Time Machine"],

    # --- Coverage diagnostics ---
    "diagnostics.coverage.title": ["ການກວມເຖິງກົດ", "تغطية القواعد", "כיסוי הכללים", "پوشش قواعد"],
    "diagnostics.coverage.detail": ["ສະແກນໜຶ່ງເທື່ອດ້ວຍຕາຕະລາງກົດປັດຈຸບັນ ແລ້ວສະແດງສິ່ງທີ່ແຕ່ລະກົດພົບ ແລະ ໂຟນເດີໃຫຍ່ທີ່ບໍ່ມີກົດໃດເຂົ້າເຖິງ.", "يُجري فحصًا واحدًا بجدول القواعد الحالي ثم يعرض ما وجدته كل قاعدة والمجلدات الكبيرة التي لا تصل إليها أي قاعدة.", "מריץ סריקה אחת עם טבלת הכללים הנוכחית ומציג מה כל כלל מצא ואילו תיקיות גדולות אין כלל שמגיע אליהן.", "یک اسکن با جدول قواعد کنونی انجام می‌دهد و نشان می‌دهد هر قاعده چه یافت و کدام پوشه‌های بزرگ را هیچ قاعده‌ای پوشش نمی‌دهد."],
    "diagnostics.coverage.run": ["ກວດສອບການກວມເຖິງ", "فحص التغطية", "בדיקת כיסוי", "بررسی پوشش"],
    "diagnostics.coverage.idle": ["ກົດທີ່ບໍ່ພົບຫຍັງ: %@", "قواعد لم تجد شيئًا: %@", "כללים שלא מצאו דבר: %@", "قواعدی که چیزی نیافتند: %@"],
    "diagnostics.coverage.uncovered": ["ໂຟນເດີໃຫຍ່ທີ່ບໍ່ມີກົດເຂົ້າເຖິງ", "مجلدات كبيرة بلا تغطية", "תיקיות גדולות ללא כיסוי", "پوشه‌های بزرگ بدون پوشش"],
    "diagnostics.coverage.rule": ["ກົດ", "قاعدة", "כלל", "قاعده"],
    "diagnostics.coverage.synthesized": ["ການສະແກນ", "فحص", "סריקה", "اسکن"],
    "diagnostics.coverage.synthesizedNote": ["ແຖວທີ່ໝາຍວ່າ «ການສະແກນ» ມາຈາກໂຄ້ດການສະແກນ — ສິ່ງຕົກຄ້າງ ແລະ ຂີດຈຳກັດຂະໜາດ ແລະ ອາຍຸ — ບໍ່ແມ່ນຈາກໄຟລ໌ກົດ.", "الصفوف المعلَّمة بـ«فحص» تأتي من شيفرة الفحص — البقايا وحدود الحجم والعمر — لا من ملف القواعد. لا تنطبق عليها مسودة قاعدة.", "שורות המסומנות ב«סריקה» מגיעות מקוד הסריקה — שאריות וספי גודל וגיל — ולא מקובץ הכללים. טיוטת כלל אינה חלה עליהן.", "ردیف‌های نشان‌دار «اسکن» از کد اسکن می‌آیند — باقی‌مانده‌ها و آستانه‌های حجم و سن — نه از پروندهٔ قواعد."],

    # --- Rule drafts ---
    "diagnostics.coverage.draftTitle": ["ຮ່າງກົດ", "مسودة قاعدة", "טיוטת כלל", "پیش‌نویس قاعده"],
    "diagnostics.coverage.draftDetail": ["ເພີ່ມສິ່ງນີ້ໃສ່ໄຟລ໌ກົດຂອງທ່ານ ແລ້ວເປີດ “ໃຊ້ໄຟລ໌ກົດກຳນົດເອງ” ໃນການຕັ້ງຄ່າ. ກ່ອນໜ້ານັ້ນຈະບໍ່ມີການລຶບຫຍັງ.", "أضف هذا إلى ملف القواعد الخاص بك ثم فعّل «استخدام ملف قواعد مخصص» في الإعدادات. لن يُحذف شيء قبل ذلك.", "הוסיפו זאת לקובץ הכללים שלכם והפעילו «שימוש בקובץ כללים מותאם» בהגדרות. עד אז דבר לא נמחק.", "این را به فایل قواعد خود اضافه کنید و در تنظیمات «استفاده از فایل قواعد سفارشی» را روشن کنید. تا آن زمان چیزی پاک نمی‌شود."],
    "diagnostics.coverage.draftCopy": ["ສຳເນົາ", "نسخ", "העתקה", "رونوشت"],
    "diagnostics.coverage.draftCannot": ["ໂຟນເດີນີ້ບໍ່ສາມາດຄຸ້ມຄອງດ້ວຍກົດໄດ້: %@", "لا يمكن تغطية هذا المجلد بقاعدة: %@", "לא ניתן לכסות תיקייה זו בכלל: %@", "این پوشه را نمی‌توان با قاعده پوشش داد: %@"],

    # --- Residue categories ---
    "cleanup.category.groupContainerResidue": ["ສິ່ງຕົກຄ້າງໃນຄອນເທນເນີຮ່ວມ", "بقايا الحاويات المشتركة", "שאריות מכולות משותפות", "باقی‌ماندهٔ محفظه‌های مشترک"],

    # --- Residue ownership ---
    "uninstall.sharedContainer": ["ແບ່ງປັນກັບ: %@", "مشترك أيضًا مع: %@", "משותף גם עם: %@", "همچنین مشترک با: %@"],
    "scan.results.ownerAction": ["ນີ້ແມ່ນແອັບໃດ?", "أي تطبيق هذا؟", "של איזו אפליקציה זה?", "این از کدام برنامه است؟"],
    "scan.results.ownerMissing": ["ບໍ່ມີແອັບທີ່ຕິດຕັ້ງສຳລັບ %@. ສຳເນົາຕົວະລະບຸແລ້ວ.", "لا يوجد تطبيق مثبَّت لـ %@. تم نسخ المعرِّف.", "לא מותקנת אפליקציה עבור %@. המזהה הועתק.", "هیچ برنامه‌ای برای %@ نصب نیست. شناسه رونوشت شد."],

    # --- Cleanup confirmation ----------------------------------------------------
    "cleanup.confirm.titleCount": ["ຍ້າຍ %d ລາຍການໄປຖັງຂີ້ເຫຍື້ອ?", "نقل %d عنصرًا إلى المهملات؟", "להעביר %d פריטים אל פח האשפה?", "انتقال %d مورد به سطل بازیافت؟"],
    "cleanup.confirm.moveAction": ["ຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ", "نقل إلى المهملات", "העבר אל פח האשפה", "انتقال به سطل بازیافت"],
    "cleanup.confirm.showItems": ["ກວດເບິ່ງແຕ່ລະລາຍການ (%d)", "مراجعة كل عنصر (%d)", "בדיקת כל פריט (%d)", "بررسی هر مورد (%d)"],
    "cleanup.confirm.hideItems": ["ປິດລາຍການ", "إخفاء القائمة", "הסתר את הרשימה", "پنهان کردن فهرست"],
    "cleanup.confirm.locations": ["ຕຳແໜ່ງ", "المواقع", "מיקומים", "مکان‌ها"],
    "cleanup.confirm.protectedCount": ["%d ຖືກປ້ອງກັນໄວ້, ບໍ່ຍ້າຍ", "%d محمية، لم تُنقل", "%d מוגנים, לא הועברו", "%d محافظت‌شده، منتقل نشد"],
    "cleanup.confirm.missingCount": ["%d ຫາຍໄປແລ້ວ, ຂ້າມໄປ", "%d اختفى بالفعل، تم تخطيه", "%d כבר אינם, דולגו", "%d از قبل رفته، رد شد"],
    "cleanup.confirm.reviewCount": ["%d ຕ້ອງການການກວດຂອງທ່ານ", "%d يحتاج إلى مراجعتك", "%d דורשים את בדיקתכם", "%d نیازمند بررسی شماست"],
    "cleanup.confirm.whyRecoverable": ["ເປັນຫຍັງຈຶ່ງກູ້ຄືນໄດ້", "لماذا يمكن استعادته", "למה אפשר לשחזר", "چرا قابل بازیابی است"],

    # --- Cleanup progress and result ---------------------------------------------
    "cleanup.preparing.title": ["ກຳລັງກວດລາຍການ", "جارٍ التحقق من العناصر", "בודק פריטים", "در حال بررسی موارد"],
    "cleanup.executing.title": ["ກຳລັງຍ້າຍໄປຖັງຂີ້ເຫຍື້ອ", "جارٍ النقل إلى المهملات", "מעביר אל פח האשפה", "در حال انتقال به سطل بازیافت"],
    "cleanup.executing.progress": ["%d ຈາກ %d", "%d من %d", "%d מתוך %d", "%d از %d"],
    "cleanup.result.reclaimAfterEmpty": [
        "ພື້ນທີ່ຫວ່າງຈະເພີ່ມຂຶ້ນ %@ ເມື່ອລ້າງຖັງຂີ້ເຫຍື້ອ",
        "تزيد المساحة المتاحة بمقدار %@ بعد إفراغ سلة المهملات",
        "השטח הפנוי יגדל ב-%@ לאחר ריקון פח האשפה",
        "پس از خالی کردن سطل بازیافت، فضای آزاد %@ بیشتر می‌شود",
    ],
    "cleanup.result.retryCount": ["ລອງໃໝ່ %d", "أعد محاولة %d", "נסה שוב %d", "تلاش دوباره %d"],
    "cleanup.result.undoAction": ["ຍ້ອນກັບການລ້າງນີ້", "تراجع عن هذا التنظيف", "בטל את הניקוי הזה", "بازگرداندن این پاک‌سازی"],
    "cleanup.result.undoUnavailable": [
        "ຍ້ອນກັບບໍ່ໄດ້: ຖັງຂີ້ເຫຍື້ອຖືກລ້າງແລ້ວ ຫຼື ລາຍການຢູ່ດິສກ໌ອື່ນ",
        "لا يمكن التراجع: أُفرغت سلة المهملات أو أن العنصر على قرص آخر",
        "לא ניתן לבטל: פח האשפה רוקן או שהפריט בכונן אחר",
        "بازگشت ممکن نیست: سطل بازیافت خالی شده یا مورد روی دیسک دیگری است",
    ],
    "cleanup.result.stopped": ["ຢຸດຫຼັງຈາກ %d ລາຍການ", "توقف بعد %d عنصرًا", "הופסק לאחר %d פריטים", "پس از %d مورد متوقف شد"],

    # --- Scan state --------------------------------------------------------------
    "scan.stopped.title": ["ສະແກນຢຸດແລ້ວ", "توقف الفحص", "הסריקה הופסקה", "اسکن متوقف شد"],
    "scan.stopped.detail": [
        "ພົບ %d ລາຍການ (%@) ກ່ອນທີ່ທ່ານຈະຢຸດ. ທ່ານຍັງລ້າງພວກມັນໄດ້.",
        "تم العثور على %d عنصرًا (%@) قبل أن توقف. لا يزال بإمكانك تنظيفها.",
        "נמצאו %d פריטים (%@) לפני שעצרתם. עדיין אפשר לנקות אותם.",
        "%d مورد (%@) پیش از توقف یافت شد. هنوز می‌توانید پاکشان کنید.",
    ],
    "scan.stopping": ["ກຳລັງຢຸດ…", "جارٍ الإيقاف…", "עוצר…", "در حال توقف…"],
    "scan.hiddenSelected": [
        "%d ລາຍການທີ່ເລືອກໄວ້ບໍ່ໄດ້ສະແດງຢູ່ນີ້",
        "%d من العناصر المحددة غير معروضة هنا",
        "%d פריטים שנבחרו אינם מוצגים כאן",
        "%d مورد انتخاب‌شده اینجا نشان داده نمی‌شود",
    ],
    "scan.nothingFoundScope": ["ບໍ່ມີຫຍັງໃນຂອບນີ້", "لا شيء في هذا النطاق", "אין דבר בהיקף הזה", "چیزی در این محدوده نیست"],

    # --- File cleanup empty states -----------------------------------------------
    "files.noDuplicatesDetail": [
        "ບໍ່ພົບໄຟລ໌ຊ້ຳໃນໂຟນເດີທີ່ Sift ສະແກນ.",
        "لا توجد ملفات مكررة في المجلدات التي فحصها Sift.",
        "לא נמצאו קבצים משוכפלים בתיקיות שסרק Sift.",
        "در پوشه‌هایی که Sift اسکن کرد فایل تکراری‌ای نیست.",
    ],

    # --- Full Disk Access and scan scope -----------------------------------------
    "permission.askTitle": ["ໃຫ້ Sift ອ່ານເພີ່ມອີກໜ້ອຍໜຶ່ງບໍ?", "هل تسمح لـ Sift بالقراءة أكثر قليلًا؟", "לאפשר ל-Sift לקרוא קצת יותר?", "اجازه می‌دهید Sift کمی بیشتر بخواند؟"],
    "permission.whyTitle": ["ເປັນຫຍັງຈຶ່ງຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ", "لماذا الوصول الكامل إلى القرص", "למה גישה מלאה לכונן", "چرا دسترسی کامل به دیسک"],
    "permission.whyBody": [
        "ມັນກວມເອົາໄຟລ໌ບັນທຶກລະບົບ ແລະ ໂຟນເດີສະໜັບສະໜູນແອັບ ທີ່ macOS ປ້ອງກັນໄວ້. ຟັງຊັນອື່ນໆໃຊ້ໄດ້ໂດຍບໍ່ຕ້ອງມີສິດນີ້.",
        "يغطي سجلات النظام ومجلدات دعم التطبيقات التي تحميها macOS. كل ما عدا ذلك يعمل بدونه.",
        "היא מכסה יומני מערכת ותיקיות תמיכה של אפליקציות ש-macOS מגן עליהן. כל השאר עובד בלעדיה.",
        "گزارش‌های سیستم و پوشه‌های پشتیبانی برنامه‌ها را در بر می‌گیرد که مک‌او‌اس محافظتشان می‌کند. بقیهٔ کارها بدون آن هم انجام می‌شود.",
    ],
    "permission.whyRevoke": [
        "ທ່ານສາມາດປິດມັນໄດ້ທຸກເວລາໃນການຕັ້ງຄ່າລະບົບ → ຄວາມເປັນສ່ວນຕົວ ແລະ ຄວາມປອດໄພ.",
        "يمكنك إيقافه في أي وقت من إعدادات النظام → الخصوصية والأمان.",
        "אפשר לכבות אותה בכל עת בהגדרות המערכת → פרטיות ואבטחה.",
        "هر زمان می‌توانید آن را در تنظیمات سیستم → حریم خصوصی و امنیت خاموش کنید.",
    ],
    "permission.openedSettings": [
        "ເປີດການຕັ້ງຄ່າລະບົບແລ້ວ. ກັບມາແລ້ວສະແກນອີກຄັ້ງ.",
        "إعدادات النظام مفتوحة. عُد وافحص مجددًا.",
        "הגדרות המערכת פתוחות. חזרו וסרקו שוב.",
        "تنظیمات سیستم باز است. برگردید و دوباره اسکن کنید.",
    ],
    "permission.protectedTitle": ["ປ້ອງກັນໂດຍ Sift", "محمي بواسطة Sift", "מוגן על ידי Sift", "محافظت‌شده توسط Sift"],
    "permission.systemProtectedTitle": ["ຕຳແໜ່ງທີ່ macOS ປິດໄວ້", "مواقع يحتفظ macOS بها مغلقة", "מיקומים ש-macOS משאיר סגורים", "مکان‌هایی که macOS بسته نگه می‌دارد"],
    "permission.restartHint": ["ຖ້າເປີດການເຂົ້າເຖິງດິສທັງໝົດແລ້ວ ໃຫ້ອອກຈາກ Sift ແລ້ວເປີດໃໝ່ — macOS ຈະນຳໃຊ້ສິດນີ້ຕອນແອັບເລີ່ມຕົ້ນ.", "إذا كان الوصول الكامل إلى القرص مفعَّلًا بالفعل، فاخرج من Sift ثم افتحه مرة أخرى — يطبّق macOS الإذن عند بدء التطبيق.", "אם „גישה מלאה לדיסק“ כבר דלוקה, צא מ-Sift ופתח אותו שוב — macOS מחיל את ההרשאה כשהאפליקציה עולה.", "اگر «دسترسی کامل به دیسک» از قبل روشن است، Sift را ببندید و دوباره باز کنید — macOS این مجوز را هنگام آغاز برنامه اعمال می‌کند."],
    "scan.skippedReason.systemRestricted": ["ຕຳແໜ່ງນີ້ເປັນຂອງ macOS ຫຼື ຜູ້ໃຊ້ອື່ນ ດັ່ງນັ້ນ Sift ຈຶ່ງອ່ານບໍ່ໄດ້.", "هذا الموقع مملوك لـ macOS أو لمستخدم آخر، لذا لا يستطيع Sift قراءته.", "המיקום הזה שייך ל-macOS או למשתמש אחר, ולכן Sift אינו יכול לקרוא אותו.", "این مکان متعلق به macOS یا کاربر دیگری است، بنابراین Sift نمی‌تواند آن را بخواند."],
    "scan.firstRun.scope": [
        "Sift ອ່ານແຄຊ໌, ໄຟລ໌ບັນທຶກ ແລະ ໂປຣແກຣມຕິດຕັ້ງໃນຕຳແໜ່ງເຫຼົ່ານີ້:",
        "يقرأ Sift الذاكرة المؤقتة والسجلات وبرامج التثبيت في هذه المواقع:",
        "Sift קורא מטמונים, יומנים ומתקינים במיקומים האלה:",
        "Sift حافظه‌های نهانی، گزارش‌ها و نصب‌کننده‌ها را در این مکان‌ها می‌خواند:",
    ],
    "scan.scopeNote": [
        "ອ່ານພຽງຊື່, ຂະໜາດ ແລະ ວັນທີ · ການຄຸມຄອບຄົບຖ້ວນຕ້ອງມີສິດເຂົ້າເຖິງດິສກ໌ຢ່າງເຕັມສ່ວນ",
        "يقرأ الأسماء والأحجام والتواريخ فقط · التغطية الكاملة تتطلب الوصول الكامل إلى القرص",
        "קורא שמות, גדלים ותאריכים בלבד · כיסוי מלא דורש גישה מלאה לכונן",
        "فقط نام‌ها، اندازه‌ها و تاریخ‌ها خوانده می‌شود · پوشش کامل نیازمند دسترسی کامل به دیسک است",
    ],

    # --- Purchase, settings and navigation ---------------------------------------
    "purchase.activate": ["ເປີດໃຊ້ລະຫັດໃບອະນຸຍາດ", "تفعيل مفتاح ترخيص", "הפעלת מפתח רישיון", "فعال‌سازی کلید مجوز"],
    "purchase.openStore": ["ຊື້ຢູ່ເວັບໄຊທ໌", "الشراء من الموقع", "לקנות באתר", "خرید از وب‌سایت"],
    "purchase.unavailable": [
        "ການຊື້ໃນແອັບໃຊ້ບໍ່ໄດ້ໃນເວີຊັນນີ້.",
        "الشراء من داخل التطبيق غير متاح في هذا الإصدار.",
        "רכישה מתוך האפליקציה אינה זמינה בגרסה הזו.",
        "خرید درون‌برنامه‌ای در این نسخه در دسترس نیست.",
    ],
    "settings.showConfirmList": ["ສະແດງລາຍການກ່ອນລ້າງ", "عرض قائمة العناصر قبل التنظيف", "הצגת רשימת הפריטים לפני הניקוי", "نمایش فهرست موارد پیش از پاک‌سازی"],
    "settings.showConfirmListWarning": [
        "ການປິດອັນນີ້ຈະເອົາຈຸດກວດສຸດທ້າຍອອກ. ລາຍການຍັງເຂົ້າຖັງຂີ້ເຫຍື້ອ ແຕ່ທ່ານຈະບໍ່ເຫັນວ່າມີຫຍັງຖືກຍ້າຍ.",
        "إيقاف هذا يزيل آخر نقطة تحقق. ستذهب العناصر إلى المهملات، لكنك لن ترى ما يُنقل.",
        "כיבוי האפשרות מסיר את נקודת הבדיקה האחרונה. הפריטים עדיין יגיעו לפח האשפה, אבל לא תראו מה מועבר.",
        "خاموش کردن این گزینه آخرین نقطهٔ بازبینی را حذف می‌کند. موارد همچنان به سطل بازیافت می‌روند، اما نمی‌بینید چه چیزی منتقل می‌شود.",
    ],
    "settings.includeHidden": ["ໃສ່ໄຟລ໌ເຊື່ອງໃນການສະແກນ", "تضمين الملفات المخفية في الفحص", "לכלול קבצים נסתרים בסריקות", "گنجاندن فایل‌های پنهان در اسکن‌ها"],
    "trash.emptyConfirmAction": ["ລຶບຢ່າງຖາວອນ", "حذف نهائي", "מחיקה לצמיתות", "حذف همیشگی"],
    "common.copyReason": ["ສຳເນົາເຫດຜົນ", "نسخ السبب", "העתקת סיבה", "رونوشت علت"],
    "common.stop": ["ຢຸດ", "إيقاف", "עצור", "توقف"],
    "cleanup.busyNotice": ["ການດຳເນີນການອື່ນຍັງດຳເນີນຢູ່. ລອງໃໝ່ອີກຄັ້ງໃນອີກສັກຄູ່.", "لا تزال عملية أخرى قيد التنفيذ. أعد المحاولة بعد قليل.", "פעולה אחרת עדיין פועלת. נסו שוב בעוד רגע.", "عملیات دیگری هنوز در حال اجراست. کمی بعد دوباره تلاش کنید."],
    "cleanup.nothingToDo": ["ຕອນນີ້ຍັງຍ້າຍສິ່ງທີ່ເລືອກບໍ່ໄດ້.", "لا يمكن نقل أي عنصر من التحديد الآن.", "כרגע אין מה מהבחירה שאפשר להעביר.", "اکنون هیچ‌کدام از موارد انتخاب‌شده قابل جابه‌جایی نیست."],
    "scan.partialBudget": ["ການສະແກນຢຸດກ່ອນເພື່ອໃຫ້ລະບົບລື່ນໄຫຼ: ຜົນລັບບໍ່ຄົບ.", "توقف الفحص مبكرًا للحفاظ على سلاسة التطبيق: النتائج جزئية.", "הסריקה הסתיימה מוקדם כדי שהאפליקציה תישאר מגיבה — התוצאות חלקיות.", "اسکن برای روان ماندن برنامه زودتر پایان یافت — نتایج ناقص است."],
    "settings.ignoreEmpty": ["ຍັງບໍ່ມີໂຟນເດີທີ່ຍົກເວັ້ນ.", "لا يوجد مجلد مستثنى بعد.", "אין עדיין תיקייה מוחרגת.", "هنوز پوشهای مستثنا نشده است."],
    "settings.addFolder": ["ເພີ່ມໂຟນເດີ", "إضافة مجلد", "הוספת תיקייה", "افزودن پوشه"],
    "settings.keepHistory": ["ຈຳນວນການສະແກນທີ່ເກັບ", "عدد عمليات الفحص المحفوظة", "מספר הסריקות לשמירה", "تعداد اسکنهای نگهداریشده"],
    "settings.launchAtLogin": ["ເປີດ Sift ຕອນເຂົ້າລະບົບ", "فتح Sift عند تسجيل الدخول", "פתיחת Sift בעת הכניסה", "باز کردن Sift هنگام ورود"],
    "common.today": ["ມື້ນີ້", "اليوم", "היום", "امروز"],
    "common.yesterday": ["ມື້ວານ", "أمس", "אתמול", "دیروز"],
    "common.daysAgo": ["%d ວັນກ່ອນ", "قبل %d يومًا", "לפני %d ימים", "%d روز پیش"],
    "settings.textSize": ["ຂະໜາດຂໍ້ຄວາມ", "حجم النص", "גודל טקסט", "اندازه متن"],
    "settings.textSizeSmall": ["ນ້ອຍ", "صغير", "קטן", "کوچک"],
    "settings.textSizeDefault": ["ຄ່າເລີ່ມຕົ້ນ", "افتراضي", "ברירת מחדל", "پیشفرض"],
    "settings.textSizeLarge": ["ໃຫຍ່", "كبير", "גדול", "بزرگ"],
    "scan.firstRun.review": ["ການລຶບລ້າງຄັ້ງທຳອິດ: ເປີດລາຍການກ່ອນຢືນຢັນ.", "أول عملية تنظيف: وسّع القائمة قبل التأكيد.", "ניקוי ראשון: פתחו את הרשימה לפני האישור.", "نخستین پاکسازی: پیش از تأیید فهرست را باز کنید."],
}

LANGUAGES = LANGUAGES + EXPANSION_2_LANGUAGES

_missing = [key for key in STRINGS if key not in STRINGS_EXPANSION_2]
_extra = [key for key in STRINGS_EXPANSION_2 if key not in STRINGS]
if _missing or _extra:
    raise SystemExit(
        f"the second expansion table is out of step with the v1 table: "
        f"{len(_missing)} missing (first: {_missing[:3]}), "
        f"{len(_extra)} extra (first: {_extra[:3]})"
    )
for _key, _row in STRINGS.items():
    _row.extend(STRINGS_EXPANSION_2[_key])
del _missing, _extra, _key, _row


# Languages added with the second international expansion: the remaining
# languages the store front offers. They are appended to every row after the
# Middle Eastern columns above, in this order.
EXPANSION_3_LANGUAGES = ["bg", "cs", "da", "el", "es-419", "fi", "hu", "id", "ms", "nb", "pt-pt", "ro", "sv", "th", "uk", "vi"]

# key: [bg, cs, da, el, es-419, fi, hu, id, ms, nb, pt-pt, ro, sv, th, uk, vi]
#
# Like the earlier expansion tables, this one must cover exactly the same keys
# as STRINGS; the merge below fails the generation when they drift apart.
STRINGS_EXPANSION_3: dict[str, list[str]] = {
    "nav.dashboard": ["Преглед", "Přehled", "Oversigt", "Επισκόπηση", "Resumen", "Yleiskatsaus", "Áttekintés", "Ringkasan", "Gambaran Keseluruhan", "Oversikt", "Visão geral", "Prezentare generală", "Översikt", "ภาพรวม", "Огляд", "Tổng quan"],
    "nav.smartScan": ["Интелигентно сканиране", "Chytré skenování", "Smart scanning", "Έξυπνη σάρωση", "Análisis inteligente", "Älyskannaus", "Intelligens vizsgálat", "Pindai Cerdas", "Imbas Pintar", "Smart skanning", "Verificação inteligente", "Scanare inteligentă", "Smart skanning", "สแกนอัจฉริยะ", "Розумне сканування", "Quét thông minh"],
    "nav.junkCleanup": ["Почистване на ненужни файлове", "Čištění nepořádku", "Skraldoprydning", "Καθαρισμός περιττών", "Limpieza de basura", "Roskien siivous", "Szemét tisztítása", "Bersihkan Sampah", "Bersih Sampah", "Søppelopprydding", "Limpeza de ficheiros inúteis", "Curățare fișiere inutile", "Skräprensning", "ล้างไฟล์ขยะ", "Очищення зайвих файлів", "Dọn tệp rác"],
    "nav.uninstaller": ["Деинсталиране", "Odinstalátor", "Afinstallation", "Απεγκατάσταση", "Desinstalador", "Asennuksen poisto", "Eltávolító", "Penghapus Aplikasi", "Penyahpasang", "Avinstallering", "Desinstalador", "Dezinstalator", "Avinstallation", "ตัวถอนการติดตั้ง", "Видалення програм", "Gỡ cài đặt"],
    "nav.fileCleanup": ["Почистване на файлове", "Čištění souborů", "Filoprydning", "Καθαρισμός αρχείων", "Limpieza de archivos", "Tiedostojen siivous", "Fájltisztítás", "Bersihkan File", "Bersih Fail", "Filopprydding", "Limpeza de ficheiros", "Curățare fișiere", "Filrensning", "ล้างไฟล์", "Очищення файлів", "Dọn tệp"],
    "nav.storageAnalysis": ["Хранилище", "Úložiště", "Lagerplads", "Αποθήκευση", "Almacenamiento", "Tallennustila", "Tárhely", "Penyimpanan", "Storan", "Lagring", "Armazenamento", "Stocare", "Lagring", "พื้นที่เก็บข้อมูล", "Сховище", "Dung lượng"],
    "nav.settings": ["Настройки", "Nastavení", "Indstillinger", "Ρυθμίσεις", "Ajustes", "Asetukset", "Beállítások", "Pengaturan", "Tetapan", "Innstillinger", "Definições", "Configurări", "Inställningar", "การตั้งค่า", "Налаштування", "Cài đặt"],
    "nav.privacy": ["Поверителност", "Soukromí", "Anonymitet", "Απόρρητο", "Privacidad", "Tietosuoja", "Adatvédelem", "Privasi", "Privasi", "Personvern", "Privacidade", "Confidențialitate", "Integritet", "ความเป็นส่วนตัว", "Конфіденційність", "Quyền riêng tư"],
    "dashboard.scanCard.title": ["Намерете какво може да се почисти безопасно", "Najděte, co lze bezpečně vyčistit", "Find det, der kan ryddes sikkert", "Βρείτε τι μπορεί να καθαριστεί με ασφάλεια", "Encuentra lo que se puede limpiar de forma segura", "Etsi turvallisesti siivottavat kohteet", "Találja meg, mi tisztítható biztonságosan", "Temukan yang dapat dibersihkan dengan aman", "Cari perkara yang boleh dibersihkan dengan selamat", "Finn det som trygt kan ryddes", "Descubra o que pode ser limpo em segurança", "Găsește ce poate fi curățat în siguranță", "Hitta det som kan rensas bort säkert", "ค้นหาสิ่งที่ล้างได้อย่างปลอดภัย", "Знайдіть те, що можна безпечно очистити", "Tìm những gì có thể dọn an toàn"],
    "dashboard.scanCard.subtitle": ["Кешове, журнали, инсталатори и остатъчни файлове. Всеки елемент показва своя източник и предназначение преди премахване.", "Mezipaměti, protokoly, instalátory a zbylé soubory. U každé položky se před odstraněním zobrazí její zdroj a účel.", "Caches, logfiler, installationsprogrammer og rester. Hvert element viser sin kilde og hensigt, før det fjernes.", "Cache, αρχεία καταγραφής, προγράμματα εγκατάστασης και αρχεία που έχουν απομείνει. Κάθε στοιχείο δείχνει την πηγή και τον σκοπό του πριν από την αφαίρεση.", "Cachés, registros, instaladores y archivos residuales. Cada elemento muestra su origen y su finalidad antes de eliminarse.", "Välimuistit, lokit, asennusohjelmat ja jäänteet. Jokainen kohde näyttää lähteensä ja tarkoituksensa ennen poistoa.", "Gyorsítótárak, naplók, telepítők és hátramaradt fájlok. Minden elem mutatja a forrását és célját az eltávolítás előtt.", "Cache, log, penginstal, dan file sisa. Setiap item menampilkan sumber dan tujuannya sebelum dihapus.", "Cache, log, pemasang dan fail sisa. Setiap item menunjukkan sumber dan tujuannya sebelum dibuang.", "Cacher, loggfiler, installasjonsprogrammer og rester. Hvert element viser kilden og formålet før det fjernes.", "Caches, registos, instaladores e ficheiros residuais. Cada item mostra a origem e a finalidade antes de ser eliminado.", "Cache-uri, jurnale, instalatoare și fișiere rămase. Fiecare element își arată sursa și scopul înainte de eliminare.", "Cacher, loggar, installationsprogram och rester. Varje objekt visar sin källa och sitt syfte innan det tas bort.", "แคช บันทึก ไฟล์ติดตั้ง และไฟล์ตกค้าง ทุกรายการจะแสดงแหล่งที่มาและวัตถุประสงค์ก่อนลบ", "Кеші, журнали, інсталятори та залишкові файли. Кожен елемент показує своє джерело й призначення до вилучення.", "Bộ nhớ đệm, nhật ký, bộ cài và tệp còn sót lại. Mỗi mục đều hiển thị nguồn gốc và mục đích trước khi xóa."],
    "dashboard.startScan": ["Стартирайте сканиране", "Spustit skenování", "Start scanning", "Έναρξη σάρωσης", "Iniciar análisis", "Aloita skannaus", "Vizsgálat indítása", "Mulai pindai", "Mula imbas", "Start skanning", "Iniciar verificação", "Începe scanarea", "Starta skanning", "เริ่มสแกน", "Почати сканування", "Bắt đầu quét"],
    "dashboard.lastScan": ["Последно сканиране: %@", "Poslední skenování: %@", "Seneste scanning: %@", "Τελευταία σάρωση: %@", "Último análisis: %@", "Viimeisin skannaus: %@", "Utolsó vizsgálat: %@", "Pemindaian terakhir: %@", "Imbasan terakhir: %@", "Siste skanning: %@", "Última verificação: %@", "Ultima scanare: %@", "Senaste skanning: %@", "สแกนล่าสุด: %@", "Останнє сканування: %@", "Lần quét cuối: %@"],
    "dashboard.neverScanned": ["Все още не е сканирано", "Zatím neskenováno", "Ikke scannet endnu", "Δεν έχει γίνει σάρωση ακόμη", "Aún sin analizar", "Ei vielä skannattu", "Még nem vizsgált", "Belum dipindai", "Belum diimbas", "Ikke skannet ennå", "Ainda não verificado", "Încă nescanat", "Inte skannat än", "ยังไม่ได้สแกน", "Ще не сканувалося", "Chưa quét lần nào"],
    "dashboard.diskUsed": ["Заето място на диска", "Využité místo", "Diskforbrug", "Χώρος δίσκου σε χρήση", "Disco usado", "Levyn käyttö", "Használt lemezterület", "Disk terpakai", "Cakera digunakan", "Diskforbruk", "Disco utilizado", "Spațiu utilizat", "Använt utrymme", "ใช้ดิสก์ไปแล้ว", "Зайнято на диску", "Dung lượng đã dùng"],
    "dashboard.diskFree": ["%@ свободно", "%@ volných", "%@ ledig", "%@ ελεύθερα", "%@ libres", "%@ vapaana", "%@ szabad", "%@ tersedia", "%@ tersedia", "%@ ledig", "%@ livres", "%@ liberi", "%@ ledigt", "ว่าง %@", "%@ вільно", "Trống %@"],
    "dashboard.suggestedCleanup": ["Препоръчано за начало", "Doporučeno začít", "Foreslået først", "Προτεινόμενα πρώτα", "Sugerido primero", "Ehdotetaan ensin", "Először javasolt", "Disarankan lebih dulu", "Disyorkan dahulu", "Foreslått først", "Sugerido primeiro", "Recomandat mai întâi", "Föreslås först", "แนะนำให้เริ่มจาก", "Спершу радимо", "Nên bắt đầu với"],
    "dashboard.recentActivity": ["Последна активност", "Nedávná aktivita", "Seneste aktivitet", "Πρόσφατη δραστηριότητα", "Actividad reciente", "Viimeaikainen toiminta", "Legutóbbi tevékenység", "Aktivitas terbaru", "Aktiviti terkini", "Nylig aktivitet", "Atividade recente", "Activitate recentă", "Senaste aktivitet", "กิจกรรมล่าสุด", "Нещодавні дії", "Hoạt động gần đây"],
    "dashboard.cleanupCompleted": ["Почистването е завършено", "Čištění dokončeno", "Oprydning fuldført", "Ο καθαρισμός ολοκληρώθηκε", "Limpieza completada", "Siivous valmis", "Tisztítás befejezve", "Pembersihan selesai", "Pembersihan selesai", "Opprydding fullført", "Limpeza concluída", "Curățare finalizată", "Rensning klar", "ทำความสะอาดเสร็จแล้ว", "Очищення завершено", "Đã dọn dẹp xong"],
    "dashboard.scanCompleted": ["Сканирането е завършено", "Skenování dokončeno", "Scanning fuldført", "Η σάρωση ολοκληρώθηκε", "Análisis completado", "Skannaus valmis", "Vizsgálat befejezve", "Pemindaian selesai", "Imbasan selesai", "Skanning fullført", "Verificação concluída", "Scanare finalizată", "Skanning klar", "สแกนเสร็จแล้ว", "Сканування завершено", "Đã quét xong"],
    "dashboard.now": ["Сега", "Nyní", "Nu", "Τώρα", "Ahora", "Nyt", "Most", "Sekarang", "Sekarang", "Nå", "Agora", "Acum", "Nu", "ตอนนี้", "Зараз", "Bây giờ"],
    "dashboard.lookSuggestions": ["Прегледайте предложенията", "Projít doporučení", "Se forslag", "Προβολή προτάσεων", "Revisar sugerencias", "Tarkastele ehdotuksia", "Javaslatok átnézése", "Tinjau saran", "Semak cadangan", "Se forslag", "Ver sugestões", "Vezi sugestiile", "Granska förslag", "ดูข้อเสนอแนะ", "Переглянути пропозиції", "Xem gợi ý"],
    "scan.phase.idle": ["Изчакване на сканиране", "Čeká na skenování", "Venter på scanning", "Αναμονή σάρωσης", "Esperando análisis", "Odottaa skannausta", "Vizsgálatra vár", "Menunggu pemindaian", "Menunggu imbasan", "Venter på skanning", "A aguardar verificação", "Se așteaptă scanarea", "Väntar på skanning", "รอการสแกน", "Очікування сканування", "Đang chờ quét"],
    "scan.phase.preparing": ["Подготовка на папки и разрешения", "Příprava složek a oprávnění", "Forbereder mapper og tilladelser", "Προετοιμασία φακέλων και δικαιωμάτων", "Preparando carpetas y permisos", "Valmistellaan kansioita ja käyttöoikeuksia", "Mappák és engedélyek előkészítése", "Menyiapkan folder dan izin", "Menyediakan folder dan kebenaran", "Forbereder mapper og tillatelser", "A preparar pastas e permissões", "Se pregătesc folderele și permisiunile", "Förbereder mappar och behörigheter", "กำลังเตรียมโฟลเดอร์และสิทธิ์", "Підготовка папок і дозволів", "Đang chuẩn bị thư mục và quyền"],
    "scan.phase.scanning": ["Сканиране", "Skenování", "Scanner", "Σάρωση", "Analizando", "Skannataan", "Vizsgálat folyamatban", "Memindai", "Mengimbas", "Skanner", "A verificar", "Se scanează", "Skannar", "กำลังสแกน", "Сканування", "Đang quét"],
    "scan.phase.indexing": ["Измерване на размери и групиране на дубликати", "Měření velikostí a seskupování duplikátů", "Måler størrelser og grupperer dubletter", "Μέτρηση μεγεθών και ομαδοποίηση διπλοτύπων", "Midiendo tamaños y agrupando duplicados", "Mitataan kokoja ja ryhmitellään kaksoiskappaleet", "Méretek mérése és duplikátumok csoportosítása", "Mengukur ukuran dan mengelompokkan duplikat", "Mengukur saiz dan mengumpulkan pendua", "Måler størrelser og grupperer duplikater", "A medir tamanhos e a agrupar duplicados", "Se măsoară dimensiunile și se grupează duplicatele", "Mäter storlekar och grupperar dubbletter", "กำลังวัดขนาดและจัดกลุ่มไฟล์ซ้ำ", "Вимірювання розмірів і групування дублікатів", "Đang đo kích thước và nhóm tệp trùng"],
    "scan.phase.ready": ["Сканирането е завършено", "Skenování dokončeno", "Scanning fuldført", "Η σάρωση ολοκληρώθηκε", "Análisis completado", "Skannaus valmis", "Vizsgálat befejezve", "Pemindaian selesai", "Imbasan selesai", "Skanning fullført", "Verificação concluída", "Scanare finalizată", "Skanning klar", "สแกนเสร็จแล้ว", "Сканування завершено", "Quét xong"],
    "scan.phase.cancelled": ["Сканирането е отменено", "Skenování zrušeno", "Scanning annulleret", "Η σάρωση ακυρώθηκε", "Análisis cancelado", "Skannaus peruttu", "Vizsgálat megszakítva", "Pemindaian dibatalkan", "Imbasan dibatalkan", "Skanning avbrutt", "Verificação cancelada", "Scanare anulată", "Skanning avbruten", "ยกเลิกการสแกนแล้ว", "Сканування скасовано", "Đã hủy quét"],
    "scan.phase.partial": ["Някои места не можаха да бъдат прочетени", "Některá místa nebylo možné načíst", "Nogle placeringer kunne ikke læses", "Ορισμένες τοποθεσίες δεν ήταν δυνατό να διαβαστούν", "No se pudieron leer algunas ubicaciones", "Joitakin sijainteja ei voitu lukea", "Néhány helyet nem sikerült beolvasni", "Beberapa lokasi tidak dapat dibaca", "Sesetengah lokasi tidak dapat dibaca", "Noen steder kunne ikke leses", "Não foi possível ler alguns locais", "Unele locații nu au putut fi citite", "Vissa platser kunde inte läsas", "อ่านบางตำแหน่งไม่ได้", "Деякі місця не вдалося прочитати", "Không đọc được một số vị trí"],
    "scan.phase.failed": ["Сканирането е неуспешно", "Skenování se nezdařilo", "Scanning mislykkedes", "Η σάρωση απέτυχε", "El análisis falló", "Skannaus epäonnistui", "A vizsgálat sikertelen", "Pemindaian gagal", "Imbasan gagal", "Skanning mislyktes", "A verificação falhou", "Scanarea a eșuat", "Skanningen misslyckades", "การสแกนล้มเหลว", "Сканування не вдалося", "Quét thất bại"],
    "scan.currentItem": ["Проверява се: %@", "Právě kontrolováno: %@", "Tjekker nu: %@", "Έλεγχος σε εξέλιξη: %@", "Comprobando: %@", "Tarkistetaan: %@", "Éppen ellenőrzés alatt: %@", "Sedang memeriksa: %@", "Sedang menyemak: %@", "Sjekker nå: %@", "A verificar: %@", "Se verifică acum: %@", "Kontrollerar nu: %@", "กำลังตรวจสอบ: %@", "Перевіряється: %@", "Đang kiểm tra: %@"],
    "scan.cancel": ["Отменете сканирането", "Zrušit skenování", "Annuller scanning", "Ακύρωση σάρωσης", "Cancelar análisis", "Peruuta skannaus", "Vizsgálat megszakítása", "Batalkan pemindaian", "Batal imbasan", "Avbryt skanning", "Cancelar verificação", "Anulează scanarea", "Avbryt skanning", "ยกเลิกการสแกน", "Скасувати сканування", "Hủy quét"],
    "scan.results": ["Резултати", "Výsledky", "Resultater", "Αποτελέσματα", "Resultados", "Tulokset", "Eredmények", "Hasil", "Hasil", "Resultater", "Resultados", "Rezultate", "Resultat", "ผลลัพธ์", "Результати", "Kết quả"],
    "scan.selectAll": ["Изберете всичко", "Vybrat vše", "Vælg alle", "Επιλογή όλων", "Seleccionar todo", "Valitse kaikki", "Összes kijelölése", "Pilih semua", "Pilih semua", "Velg alle", "Selecionar tudo", "Selectează tot", "Markera alla", "เลือกทั้งหมด", "Вибрати все", "Chọn tất cả"],
    "scan.deselectAll": ["Премахнете избора", "Zrušit výběr", "Fravælg alle", "Αποεπιλογή όλων", "Deseleccionar todo", "Poista valinnat", "Kijelölés megszüntetése", "Batalkan semua pilihan", "Nyahpilih semua", "Fjern all markering", "Desselecionar tudo", "Deselectează tot", "Avmarkera alla", "ยกเลิกการเลือกทั้งหมด", "Зняти вибір", "Bỏ chọn tất cả"],
    "scan.selectAllShown": ["Изберете всички показани (%d)", "Vybrat vše zobrazené (%d)", "Vælg alle viste (%d)", "Επιλογή όλων των εμφανιζόμενων (%d)", "Seleccionar los mostrados (%d)", "Valitse kaikki näkyvät (%d)", "Minden látható kijelölése (%d)", "Pilih semua yang ditampilkan (%d)", "Pilih semua yang dipaparkan (%d)", "Velg alle viste (%d)", "Selecionar os apresentados (%d)", "Selectează tot ce este afișat (%d)", "Markera alla visade (%d)", "เลือกทั้งหมดที่แสดง (%d)", "Вибрати всі показані (%d)", "Chọn tất cả mục hiển thị (%d)"],
    "scan.nothingFound": ["Няма какво да се почисти", "Není co čistit", "Intet at rydde op", "Δεν υπάρχει τίποτα για καθαρισμό", "Nada que limpiar", "Ei siivottavaa", "Nincs tisztítanivaló", "Tidak ada yang perlu dibersihkan", "Tiada apa-apa untuk dibersihkan", "Ingenting å rydde", "Nada para limpar", "Nimic de curățat", "Inget att rensa", "ไม่มีอะไรให้ล้าง", "Нічого очищати", "Không có gì cần dọn"],
    "scan.nothingFoundDetail": ["Sift не намери кешове, журнали, инсталатори или остатъци, които си струва да се премахнат.", "Sift nenašel žádné mezipaměti, protokoly, instalátory ani zbytky, které by stálo za to odstranit.", "Sift fandt ingen caches, logfiler, installationsprogrammer eller rester, der er værd at fjerne.", "Το Sift δεν βρήκε cache, αρχεία καταγραφής, προγράμματα εγκατάστασης ή υπολείμματα που αξίζει να αφαιρεθούν.", "Sift no encontró cachés, registros, instaladores ni restos que valga la pena eliminar.", "Sift ei löytänyt välimuisteja, lokeja, asennusohjelmia tai jäänteitä, jotka kannattaisi poistaa.", "A Sift nem talált eltávolításra érdemes gyorsítótárat, naplót, telepítőt vagy maradványt.", "Sift tidak menemukan cache, log, penginstal, atau sisa yang perlu dihapus.", "Sift tidak menemui cache, log, pemasang atau sisa tinggalan yang perlu dibuang.", "Sift fant ingen cacher, loggfiler, installasjonsprogrammer eller rester som er verdt å fjerne.", "O Sift não encontrou caches, registos, instaladores nem resíduos que valha a pena eliminar.", "Sift nu a găsit cache-uri, jurnale, instalatoare sau reziduuri care merită eliminate.", "Sift hittade inga cacher, loggar, installationsprogram eller rester som är värda att ta bort.", "Sift ไม่พบแคช บันทึก ไฟล์ติดตั้ง หรือไฟล์ตกค้างที่ควรลบ", "Sift не знайшов кешів, журналів, інсталяторів чи залишків, які варто видалити.", "Sift không tìm thấy bộ nhớ đệm, nhật ký, bộ cài hay tệp còn sót nào đáng xóa."],
    "scan.partialNotice": ["Пропуснати места: %d", "Přeskočeno míst: %d", "%d placeringer blev sprunget over", "Παραλείφθηκαν %d τοποθεσίες", "Se omitieron %d ubicaciones", "%d sijaintia ohitettiin", "%d hely kihagyva", "%d lokasi dilewati", "%d lokasi dilangkau", "%d steder ble hoppet over", "%d locais ignorados", "Locații ignorate: %d", "%d platser hoppades över", "ข้ามไป %d ตำแหน่ง", "Пропущено місць: %d", "Đã bỏ qua %d vị trí"],
    "scan.openSystemSettings": ["Отворете Системни настройки", "Otevřít Nastavení systému", "Åbn Systemindstillinger", "Άνοιγμα Ρυθμίσεων συστήματος", "Abrir Ajustes del Sistema", "Avaa Järjestelmäasetukset", "Rendszerbeállítások megnyitása", "Buka Pengaturan Sistem", "Buka Tetapan Sistem", "Åpne Systeminnstillinger", "Abrir Definições do Sistema", "Deschide Configurările sistemului", "Öppna Systeminställningar", "เปิดการตั้งค่าระบบ", "Відкрити Системні налаштування", "Mở Cài đặt Hệ thống"],
    "scan.skippedReason.permissionDenied": ["Sift се нуждае от допълнително разрешение за това място.", "Sift potřebuje pro toto místo zvláštní oprávnění.", "Sift kræver ekstra tilladelse til denne placering.", "Το Sift χρειάζεται πρόσθετη άδεια για αυτή την τοποθεσία.", "Esta ubicación necesita un permiso adicional.", "Sift tarvitsee lisäkäyttöoikeuden tähän sijaintiin.", "A Siftnek további engedélyre van szüksége ehhez a helyhez.", "Sift memerlukan izin tambahan untuk lokasi ini.", "Sift memerlukan kebenaran tambahan untuk lokasi ini.", "Sift trenger ekstra tillatelse for dette stedet.", "Este local necessita de uma permissão adicional.", "Sift are nevoie de o permisiune suplimentară pentru această locație.", "Sift behöver extra behörighet för den här platsen.", "Sift ต้องได้รับสิทธิ์เพิ่มเติมสำหรับตำแหน่งนี้", "Sift потрібен додатковий дозвіл для цього місця.", "Sift cần thêm quyền cho vị trí này."],
    "scan.skippedReason.protectedLocation": ["Sift никога не докосва това място, за да защити вашите файлове.", "Sift toto místo nikdy neupravuje, aby ochránil vaše soubory.", "Sift rører aldrig denne placering for at beskytte dine filer.", "Το Sift δεν αγγίζει ποτέ αυτή την τοποθεσία, για να προστατεύει τα αρχεία σας.", "Sift nunca toca esta ubicación para proteger tus archivos.", "Sift ei koskaan koske tähän sijaintiin tiedostojesi suojaamiseksi.", "A Sift soha nem nyúl ehhez a helyhez, hogy védje a fájljait.", "Sift tidak pernah menyentuh lokasi ini, demi melindungi file Anda.", "Sift tidak pernah menyentuh lokasi ini, demi melindungi fail anda.", "Sift berører aldri dette stedet, for å beskytte filene dine.", "O Sift nunca mexe neste local, para proteger os seus ficheiros.", "Sift nu atinge niciodată această locație, pentru a-ți proteja fișierele.", "Sift rör aldrig den här platsen, för att skydda dina filer.", "Sift จะไม่แตะต้องตำแหน่งนี้เพื่อปกป้องไฟล์ของคุณ", "Sift ніколи не торкається цього місця, щоб захистити ваші файли.", "Sift không bao giờ đụng đến vị trí này để bảo vệ tệp của bạn."],
    "scan.skippedReason.fileNotFound": ["Елементът изчезна по време на сканирането и беше пропуснат.", "Položka během skenování zmizela, proto byla přeskočena.", "Elementet forsvandt under scanningen og blev sprunget over.", "Το στοιχείο εξαφανίστηκε κατά τη σάρωση και παραλείφθηκε.", "El elemento desapareció durante el análisis, por lo que se omitió.", "Kohde katosi skannauksen aikana, joten se ohitettiin.", "Az elem eltűnt a vizsgálat közben, ezért kihagytuk.", "Item hilang selama pemindaian, jadi dilewati.", "Item hilang semasa imbasan, jadi dilangkau.", "Elementet forsvant under skanningen og ble hoppet over.", "O item desapareceu durante a verificação, pelo que foi ignorado.", "Elementul a dispărut în timpul scanării, așa că a fost ignorat.", "Objektet försvann under skanningen och hoppades över.", "รายการนี้หายไประหว่างการสแกน จึงถูกข้ามไป", "Елемент зник під час сканування, тому його пропущено.", "Mục này đã biến mất trong khi quét nên đã bị bỏ qua."],
    "scan.skippedReason.partialFailure": ["Част от това място не можа да бъде прочетена.", "Část tohoto místa nebylo možné načíst.", "En del af denne placering kunne ikke læses.", "Ένα μέρος αυτής της τοποθεσίας δεν ήταν δυνατό να διαβαστεί.", "No se pudo leer parte de esta ubicación.", "Osaa tästä sijainnista ei voitu lukea.", "A hely egy részét nem sikerült beolvasni.", "Sebagian lokasi ini tidak dapat dibaca.", "Sebahagian lokasi ini tidak dapat dibaca.", "En del av dette stedet kunne ikke leses.", "Não foi possível ler parte deste local.", "O parte a acestei locații nu a putut fi citită.", "En del av den här platsen kunde inte läsas.", "อ่านข้อมูลบางส่วนของตำแหน่งนี้ไม่ได้", "Частину цього місця не вдалося прочитати.", "Không đọc được một phần của vị trí này."],
    "scan.skippedReason.timedOut": ["Тази папка не отговори, затова беше пропусната.", "Tato složka neodpověděla, a byla proto přeskočena.", "Denne mappe svarede ikke og blev sprunget over.", "Αυτός ο φάκελος δεν απάντησε, οπότε παραλείφθηκε.", "Esta carpeta no respondió, así que se omitió.", "Tämä kansio ei vastannut, joten se ohitettiin.", "Ez a mappa nem válaszolt, ezért ki lett hagyva.", "Folder ini tidak merespons, jadi dilewati.", "Folder ini tidak bertindak balas, jadi dilangkau.", "Denne mappen svarte ikke og ble hoppet over.", "Esta pasta não respondeu, pelo que foi ignorada.", "Acest dosar nu a răspuns, deci a fost ignorat.", "Den här mappen svarade inte och hoppades över.", "โฟลเดอร์นี้ไม่ตอบสนอง จึงถูกข้ามไป", "Ця папка не відповіла, тому її пропущено.", "Thư mục này không phản hồi nên đã bị bỏ qua."],
    "cleanup.category.applicationCache": ["Кешове на приложения", "Mezipaměti aplikací", "App-caches", "Cache εφαρμογών", "Cachés de aplicaciones", "Sovellusten välimuistit", "Alkalmazások gyorsítótárai", "Cache aplikasi", "Cache apl", "App-cacher", "Caches de aplicações", "Cache-uri ale aplicațiilor", "Appcacher", "แคชของแอป", "Кеші програм", "Bộ nhớ đệm ứng dụng"],
    "cleanup.category.logs": ["Журнали", "Protokoly", "Logfiler", "Αρχεία καταγραφής", "Registros", "Lokit", "Naplók", "Log", "Log", "Loggfiler", "Registos", "Jurnale", "Loggar", "บันทึก", "Журнали", "Nhật ký"],
    "cleanup.category.installers": ["Стари инсталатори", "Staré instalátory", "Gamle installationsprogrammer", "Παλιά προγράμματα εγκατάστασης", "Instaladores antiguos", "Vanhat asennusohjelmat", "Régi telepítők", "Penginstal lama", "Pemasang lama", "Gamle installasjonsprogrammer", "Instaladores antigos", "Instalatoare vechi", "Gamla installationsprogram", "ไฟล์ติดตั้งเก่า", "Старі інсталятори", "Bộ cài cũ"],
    "cleanup.category.temporaryFiles": ["Временни файлове", "Dočasné soubory", "Midlertidige filer", "Προσωρινά αρχεία", "Archivos temporales", "Väliaikaiset tiedostot", "Ideiglenes fájlok", "File sementara", "Fail sementara", "Midlertidige filer", "Ficheiros temporários", "Fișiere temporare", "Tillfälliga filer", "ไฟล์ชั่วคราว", "Тимчасові файли", "Tệp tạm"],
    "cleanup.category.largeFiles": ["Големи файлове", "Velké soubory", "Store filer", "Μεγάλα αρχεία", "Archivos grandes", "Suuret tiedostot", "Nagy fájlok", "File besar", "Fail besar", "Store filer", "Ficheiros grandes", "Fișiere mari", "Stora filer", "ไฟล์ขนาดใหญ่", "Великі файли", "Tệp lớn"],
    "cleanup.category.oldFiles": ["Стари файлове", "Staré soubory", "Gamle filer", "Παλιά αρχεία", "Archivos antiguos", "Vanhat tiedostot", "Régi fájlok", "File lama", "Fail lama", "Gamle filer", "Ficheiros antigos", "Fișiere vechi", "Gamla filer", "ไฟล์เก่า", "Старі файли", "Tệp cũ"],
    "cleanup.category.duplicateFiles": ["Дубликати", "Duplikáty souborů", "Dublerede filer", "Διπλότυπα αρχεία", "Archivos duplicados", "Kaksoiskappaleet", "Duplikált fájlok", "File duplikat", "Fail pendua", "Duplikatfiler", "Ficheiros duplicados", "Fișiere duplicate", "Dubblettfiler", "ไฟล์ซ้ำ", "Дублікати файлів", "Tệp trùng"],
    "cleanup.category.applicationResidue": ["Остатъци от приложения", "Pozůstatky aplikací", "App-rester", "Υπολείμματα εφαρμογών", "Restos de aplicaciones", "Sovellusten jäänteet", "Alkalmazás-maradványok", "Sisa aplikasi", "Sisa apl", "App-rester", "Resíduos de aplicações", "Reziduuri ale aplicațiilor", "Apprester", "ไฟล์ตกค้างจากแอป", "Залишки програм", "Tệp còn sót của ứng dụng"],
    "cleanup.category.developerArtifacts": ["Артефакти от компилация", "Artefakty sestavení", "Build-artefakter", "Αρχεία δημιουργίας", "Artefactos de compilación", "Käännöksen tuotokset", "Fordítási termékek", "Artefak build", "Artifak binaan", "Byggeartefakter", "Artefactos de compilação", "Artefacte de compilare", "Byggartefakter", "ไฟล์ที่สร้างจากการคอมไพล์", "Артефакти збірки", "Tệp tạo ra khi biên dịch"],

    "cleanup.explanation.cache": ["Приложенията създават тези файлове отново при следващото си стартиране.", "Aplikace tyto soubory při příštím spuštění znovu vytvoří.", "Apps genskaber disse filer, næste gang de kører.", "Οι εφαρμογές δημιουργούν ξανά αυτά τα αρχεία την επόμενη φορά που θα εκτελεστούν.", "Las aplicaciones regeneran estos archivos la próxima vez que se ejecutan.", "Sovellukset luovat nämä tiedostot uudelleen seuraavalla käynnistyskerralla.", "Az alkalmazások a következő futáskor újra létrehozzák ezeket a fájlokat.", "Aplikasi membangun ulang file ini saat dijalankan lagi.", "Apl akan membina semula fail ini apabila dijalankan semula.", "Apper bygger disse filene på nytt neste gang de kjøres.", "As aplicações recriam estes ficheiros na próxima vez que são executadas.", "Aplicațiile recreează aceste fișiere la următoarea rulare.", "Appar bygger upp dessa filer igen nästa gång de körs.", "แอปจะสร้างไฟล์เหล่านี้ใหม่เมื่อเปิดใช้งานครั้งถัดไป", "Програми створять ці файли заново під час наступного запуску.", "Ứng dụng sẽ tạo lại các tệp này trong lần chạy tiếp theo."],
    "cleanup.explanation.logs": ["Файлове с журнали, по-стари от %d дни. Те не влияят на работата на приложенията.", "Soubory protokolů starší než %d dní. Nemají vliv na chod aplikací.", "Logfiler ældre end %d dage. De påvirker ikke apps' funktion.", "Αρχεία καταγραφής παλαιότερα από %d ημέρες. Δεν επηρεάζουν τη λειτουργία των εφαρμογών.", "Archivos de registro de más de %d días. No afectan al funcionamiento de las aplicaciones.", "Lokitiedostot, jotka ovat yli %d päivää vanhoja. Ne eivät vaikuta sovellusten toimintaan.", "%d napnál régebbi naplófájlok. Nincsenek hatással az alkalmazások működésére.", "File log yang lebih lama dari %d hari. Tidak memengaruhi cara aplikasi berjalan.", "Fail log yang lebih lama daripada %d hari. Ia tidak menjejaskan cara apl berjalan.", "Loggfiler eldre enn %d dager. De påvirker ikke hvordan apper kjører.", "Ficheiros de registo com mais de %d dias. Não afetam o funcionamento das aplicações.", "Fișiere jurnal mai vechi de %d zile. Nu afectează modul în care rulează aplicațiile.", "Loggfiler äldre än %d dagar. De påverkar inte hur appar fungerar.", "ไฟล์บันทึกที่เก่ากว่า %d วัน ไม่ส่งผลต่อการทำงานของแอป", "Файли журналів, старші за %d днів. Вони не впливають на роботу програм.", "Tệp nhật ký cũ hơn %d ngày. Chúng không ảnh hưởng đến cách ứng dụng chạy."],
    "cleanup.explanation.logsItem": ["Остарели файлове с журнали. Премахването им не променя работата на приложенията.", "Zastaralé soubory protokolů. Jejich odstranění nezmění chod aplikací.", "Forældede logfiler. Fjernelse ændrer ikke, hvordan apps kører.", "Παλιά αρχεία καταγραφής. Η αφαίρεσή τους δεν αλλάζει τη λειτουργία των εφαρμογών.", "Archivos de registro obsoletos. Eliminarlos no cambia el funcionamiento de las aplicaciones.", "Vanhentuneet lokitiedostot. Niiden poistaminen ei muuta sovellusten toimintaa.", "Elavult naplófájlok. Eltávolításuk nem változtatja meg az alkalmazások működését.", "File log usang. Menghapusnya tidak mengubah cara aplikasi berjalan.", "Fail log usang. Membuangnya tidak mengubah cara apl berjalan.", "Utdaterte loggfiler. Å fjerne dem endrer ikke hvordan apper kjører.", "Ficheiros de registo obsoletos. Eliminá-los não altera o funcionamento das aplicações.", "Fișiere jurnal vechi. Eliminarea lor nu schimbă modul în care rulează aplicațiile.", "Föråldrade loggfiler. Att ta bort dem ändrar inte hur appar fungerar.", "ไฟล์บันทึกที่ไม่ได้ใช้แล้ว การลบออกไม่เปลี่ยนการทำงานของแอป", "Застарілі файли журналів. Їхнє вилучення не змінює роботу програм.", "Tệp nhật ký cũ. Xóa chúng không làm thay đổi cách ứng dụng chạy."],
    "cleanup.explanation.systemLogsItem": ["Остарели системни журнали. За четенето на някои от тях е нужен Пълен достъп до диска.", "Zastaralé systémové protokoly. Ke čtení některých z nich je potřeba Úplný přístup k disku.", "Forældede systemlogfiler. Læsning af nogle kræver fuld diskadgang.", "Παλιά αρχεία καταγραφής συστήματος. Για την ανάγνωση ορισμένων απαιτείται Πλήρης πρόσβαση στον δίσκο.", "Archivos de registro del sistema obsoletos. Para leer algunos se necesita Acceso total al disco.", "Vanhentuneet järjestelmän lokitiedostot. Joidenkin lukeminen vaatii täyden levynkäyttöoikeuden.", "Elavult rendszernapló-fájlok. Némelyik olvasásához Teljes lemezhozzáférés kell.", "File log sistem yang usang. Membaca sebagiannya memerlukan Akses Disk Penuh.", "Fail log sistem usang. Membaca sebahagian daripadanya memerlukan Akses Cakera Penuh.", "Utdaterte systemloggfiler. Lesing av noen krever full disktilgang.", "Ficheiros de registo do sistema obsoletos. A leitura de alguns requer Acesso Total ao Disco.", "Fișiere jurnal de sistem vechi. Citirea unora dintre ele necesită Acces complet la disc.", "Föråldrade systemloggar. Att läsa vissa av dem kräver fullskivåtkomst.", "ไฟล์บันทึกของระบบที่ไม่ได้ใช้แล้ว การอ่านบางไฟล์ต้องใช้การเข้าถึงดิสก์ทั้งหมด", "Застарілі системні журнали. Для читання деяких із них потрібен Повний доступ до диска.", "Tệp nhật ký hệ thống cũ. Một số tệp cần Quyền truy cập Toàn bộ Đĩa để đọc."],
    "cleanup.explanation.installers": ["Инсталатори, които вече сте използвали. Може да ви потрябват, затова потвърдете първо.", "Instalátory, které jste už použili. Možná je ještě budete potřebovat, proto je nejprve potvrďte.", "Installationsprogrammer, du allerede har brugt. Du har muligvis stadig brug for dem, så bekræft først.", "Προγράμματα εγκατάστασης που έχετε ήδη χρησιμοποιήσει. Μπορεί να τα χρειαστείτε ακόμη, οπότε επιβεβαιώστε πρώτα.", "Instaladores que ya usaste. Puede que aún los necesites, así que confirma antes.", "Asennusohjelmat, joita olet jo käyttänyt. Saatat tarvita niitä vielä, joten vahvista ensin.", "Már használt telepítők. Lehet, hogy még szüksége van rájuk, ezért előbb erősítse meg.", "Penginstal yang sudah Anda gunakan. Anda mungkin masih memerlukannya, jadi konfirmasi dulu.", "Pemasang yang telah anda gunakan. Anda mungkin masih memerlukannya, jadi sahkan dahulu.", "Installasjonsprogrammer du allerede har brukt. Du kan fortsatt trenge dem, så bekreft først.", "Instaladores que já utilizou. Pode ainda precisar deles, por isso confirme primeiro.", "Instalatoare pe care le-ai folosit deja. S-ar putea să ai încă nevoie de ele, așa că verifică mai întâi.", "Installationsprogram du redan har använt. Du kan fortfarande behöva dem, så bekräfta först.", "ไฟล์ติดตั้งที่คุณใช้แล้ว คุณอาจยังต้องใช้ โปรดยืนยันก่อน", "Інсталятори, які ви вже використали. Вони можуть ще знадобитися, тож спершу підтвердьте.", "Bộ cài bạn đã dùng. Bạn vẫn có thể cần chúng, hãy xác nhận trước."],
    "cleanup.explanation.temporary": ["Временни файлове, оставени от приложенията.", "Dočasné soubory zanechané aplikacemi.", "Midlertidige filer efterladt af apps.", "Προσωρινά αρχεία εργασίας που αφήνουν οι εφαρμογές.", "Archivos temporales que dejan las aplicaciones.", "Sovellusten jälkeensä jättämät väliaikaistiedostot.", "Alkalmazások által hátrahagyott ideiglenes fájlok.", "File sementara yang ditinggalkan aplikasi.", "Fail sementara yang ditinggalkan oleh apl.", "Midlertidige filer etterlatt av apper.", "Ficheiros temporários deixados pelas aplicações.", "Fișiere temporare lăsate în urmă de aplicații.", "Tillfälliga filer som lämnats kvar av appar.", "ไฟล์ชั่วคราวที่แอปทิ้งไว้", "Тимчасові файли, залишені програмами.", "Tệp tạm do ứng dụng để lại."],
    "cleanup.explanation.xcodeArchives": ["Архивирани билдове. Проектът може да бъде архивиран отново, но този архив не може да бъде възстановен.", "Archivované buildy. Projekt lze archivovat znovu, ale toto archivum obnovit nelze.", "Arkiverede builds. Projektet kan arkiveres igen, men dette arkiv kan ikke gendannes.", "Αρχειοθετημένα builds. Το έργο μπορεί να αρχειοθετηθεί ξανά, αλλά αυτό το αρχείο δεν ανακτάται.", "Compilaciones archivadas. El proyecto se puede archivar de nuevo, pero este archivo no se puede recuperar.", "Arkistoidut buildit. Projektin voi arkistoida uudelleen, mutta tätä arkistoa ei voi palauttaa.", "Archivált buildek. A projekt újra archiválható, de ez az archívum nem állítható vissza.", "Build yang diarsipkan. Proyek dapat diarsipkan ulang, tetapi arsip ini tidak dapat dipulihkan.", "Binaan yang diarkibkan. Projek boleh diarkibkan semula, tetapi arkib ini tidak boleh dipulihkan.", "Arkiverte bygg. Prosjektet kan arkiveres på nytt, men dette arkivet kan ikke gjenopprettes.", "Compilações arquivadas. O projeto pode ser arquivado de novo, mas este arquivo não pode ser recuperado.", "Build-uri arhivate. Proiectul poate fi arhivat din nou, dar această arhivă nu poate fi recuperată.", "Arkiverade byggen. Projektet kan arkiveras igen, men detta arkiv kan inte återställas.", "บิลด์ที่เก็บถาวรแล้ว โปรเจกต์เก็บถาวรใหม่ได้ แต่ไฟล์เก็บถาวรนี้กู้คืนไม่ได้", "Архівовані збірки. Проєкт можна заархівувати знову, але цей архів відновити неможливо.", "Bản dựng đã lưu trữ. Có thể lưu trữ lại dự án, nhưng bản lưu trữ này không khôi phục được."],
    "cleanup.explanation.buildArtifacts": ["Резултат от компилатор. Следващото компилиране ще го създаде отново.", "Výstup kompilátoru. Další sestavení ho vytvoří znovu.", "Output fra en kompilering. Næste build genskaber det.", "Έξοδος μεταγλωττιστή. Η επόμενη μεταγλώττιση θα το δημιουργήσει ξανά.", "Resultado de una compilación. La próxima compilación lo vuelve a crear.", "Kääntäjän tuottama tulos. Seuraava käännös luo sen uudelleen.", "Fordító által írt kimenet. A következő fordítás újra létrehozza.", "Keluaran dari kompilasi. Build berikutnya akan membuatnya lagi.", "Output daripada kompilasi. Binaan seterusnya akan menciptanya semula.", "Utdata fra en kompilering. Neste bygg lager det på nytt.", "Resultado de uma compilação. A próxima compilação volta a criá-lo.", "Rezultatul unei compilări. Următoarea compilare îl recreează.", "Utdata från en kompilering. Nästa bygge skapar det igen.", "ผลลัพธ์ที่คอมไพเลอร์สร้างขึ้น การคอมไพล์ครั้งต่อไปจะสร้างใหม่", "Результат роботи компілятора. Наступне збирання створить його знову.", "Kết quả do trình biên dịch tạo ra. Lần biên dịch sau sẽ tạo lại."],

    "cleanup.explanation.simulatorDevices": ["Устройства на симулатора и всичко инсталирано в тях. Устройството може да се създаде отново; приложенията в него трябва да се инсталират наново.", "Zařízení simulátoru a vše, co je v nich nainstalováno. Zařízení lze vytvořit znovu; aplikace v něm je nutné nainstalovat znovu.", "Simulatorenheder og alt, hvad der er installeret i dem. Enheden kan oprettes igen; appene i den skal installeres igen.", "Συσκευές προσομοιωτή και ό,τι είναι εγκατεστημένο σε αυτές. Η συσκευή μπορεί να δημιουργηθεί ξανά· οι εφαρμογές μέσα της πρέπει να εγκατασταθούν ξανά.", "Dispositivos del simulador y todo lo instalado en ellos. El dispositivo se puede crear de nuevo; las apps que contiene hay que instalarlas otra vez.", "Simulaattorilaitteet ja kaikki niihin asennettu. Laitteen voi luoda uudelleen; sen sisältämät sovellukset on asennettava uudelleen.", "Szimulátor-eszközök és minden, ami bennük telepítve van. Az eszköz újra létrehozható; a benne lévő appokat újra kell telepíteni.", "Perangkat simulator dan semua yang terpasang di dalamnya. Perangkat dapat dibuat ulang; aplikasi di dalamnya harus dipasang ulang.", "Peranti simulator dan semua yang dipasang di dalamnya. Peranti boleh dicipta semula; apl di dalamnya perlu dipasang semula.", "Simulatorenheter og alt som er installert i dem. Enheten kan opprettes på nytt; appene i den må installeres på nytt.", "Dispositivos do simulador e tudo o que está instalado neles. O dispositivo pode ser criado de novo; as aplicações dentro dele têm de ser instaladas outra vez.", "Dispozitive de simulator și tot ce este instalat în ele. Dispozitivul poate fi recreat; aplicațiile din el trebuie reinstalate.", "Simulatorenheter och allt som är installerat i dem. Enheten kan skapas igen; apparna i den måste installeras om.", "อุปกรณ์จำลองและทุกอย่างที่ติดตั้งอยู่ข้างใน สร้างอุปกรณ์ใหม่ได้ แต่แอปข้างในต้องติดตั้งใหม่", "Пристрої симулятора й усе, що в них встановлено. Пристрій можна створити знову; застосунки в ньому доведеться встановлювати заново.", "Thiết bị giả lập và mọi thứ được cài trong đó. Có thể tạo lại thiết bị; ứng dụng bên trong phải cài lại."],
    "cleanup.explanation.largeFiles": ["Файлове, по-големи от %@. Sift никога не гадае: вие решавате кои да премахнете.", "Soubory větší než %@. Sift nic neodhaduje: rozhodujete vy, co odstranit.", "Filer større end %@. Sift gætter aldrig: du beslutter, hvad der skal fjernes.", "Αρχεία μεγαλύτερα από %@. Το Sift δεν μαντεύει: εσείς αποφασίζετε ποια θα αφαιρεθούν.", "Archivos de más de %@. Sift no adivina: tú decides cuáles eliminar.", "Tiedostot, jotka ovat suurempia kuin %@. Sift ei koskaan arvaa: sinä päätät, mitkä poistetaan.", "%@-nál nagyobb fájlok. A Sift soha nem találgat: Ön dönti el, mi kerüljön eltávolításra.", "File yang lebih besar dari %@. Sift tidak pernah menebak: Anda yang memutuskan mana yang dihapus.", "Fail yang lebih besar daripada %@. Sift tidak pernah meneka: anda yang menentukan yang mana untuk dibuang.", "Filer større enn %@. Sift gjetter aldri: du bestemmer hva som fjernes.", "Ficheiros com mais de %@. O Sift não adivinha: a decisão é sua.", "Fișiere mai mari de %@. Sift nu ghicește niciodată: tu decizi ce se elimină.", "Filer större än %@. Sift gissar aldrig: du bestämmer vad som ska tas bort.", "ไฟล์ที่ใหญ่กว่า %@ Sift ไม่เดา คุณเป็นผู้ตัดสินว่าจะลบไฟล์ใด", "Файли, більші за %@. Sift ніколи не вгадує: ви вирішуєте, які видалити.", "Tệp lớn hơn %@. Sift không đoán: bạn quyết định xóa tệp nào."],
    "cleanup.explanation.largeFilesItem": ["Голям файл. Sift никога не гадае: вие решавате дали да го премахнете.", "Velký soubor. Sift nic neodhaduje: rozhodujete vy, co odstranit.", "En stor fil. Sift gætter aldrig: du beslutter, hvad der skal fjernes.", "Ένα μεγάλο αρχείο. Το Sift δεν μαντεύει: εσείς αποφασίζετε αν θα αφαιρεθεί.", "Un archivo grande. Sift no adivina: tú decides cuáles eliminar.", "Suuri tiedosto. Sift ei koskaan arvaa: sinä päätät, poistetaanko se.", "Nagy fájl. A Sift soha nem találgat: Ön dönti el, mi kerüljön eltávolításra.", "File besar. Sift tidak pernah menebak: Anda yang memutuskan mana yang dihapus.", "Fail besar. Sift tidak pernah meneka: anda yang menentukan yang mana untuk dibuang.", "En stor fil. Sift gjetter aldri: du bestemmer hva som fjernes.", "Um ficheiro grande. O Sift não adivinha: a decisão é sua.", "Un fișier mare. Sift nu ghicește niciodată: tu decizi ce se elimină.", "En stor fil. Sift gissar aldrig: du bestämmer vad som ska tas bort.", "ไฟล์ขนาดใหญ่ Sift ไม่เดา คุณเป็นผู้ตัดสินว่าจะลบไฟล์ใด", "Великий файл. Sift ніколи не вгадує: ви вирішуєте, чи видаляти його.", "Một tệp lớn. Sift không đoán: bạn quyết định xóa tệp nào."],
    "cleanup.explanation.oldFiles": ["Не са променяни от %d дни и са по-големи от 10 MB.", "Neupraveno %d dní a větší než 10 MB.", "Ikke ændret i %d dage og større end 10 MB.", "Χωρίς τροποποίηση για %d ημέρες και μεγαλύτερα από 10 MB.", "Sin modificaciones durante %d días y de más de 10 MB.", "Ei muutettu %d päivään ja suurempi kuin 10 Mt.", "%d napja nem módosult, és nagyobb 10 MB-nál.", "Tidak diubah selama %d hari dan lebih besar dari 10 MB.", "Tidak diubah selama %d hari dan lebih besar daripada 10 MB.", "Ikke endret på %d dager og større enn 10 MB.", "Sem alterações há %d dias e com mais de 10 MB.", "Nemodificat de %d zile și mai mare de 10 MB.", "Inte ändrad på %d dagar och större än 10 MB.", "ไม่มีการแก้ไขมา %d วัน และมีขนาดใหญ่กว่า 10 MB", "Не змінювалися %d днів і більші за 10 МБ.", "Không sửa đổi trong %d ngày và lớn hơn 10 MB."],
    "cleanup.explanation.oldFilesItem": ["Не са променяни отдавна и са по-големи от 10 MB.", "Dlouho neupraveno a větší než 10 MB.", "Ikke ændret i lang tid og større end 10 MB.", "Χωρίς τροποποίηση για μεγάλο διάστημα και μεγαλύτερα από 10 MB.", "Sin modificaciones durante mucho tiempo y de más de 10 MB.", "Ei muutettu pitkään aikaan ja suurempi kuin 10 Mt.", "Hosszú ideje nem módosult, és nagyobb 10 MB-nál.", "Sudah lama tidak diubah dan lebih besar dari 10 MB.", "Sudah lama tidak diubah dan lebih besar daripada 10 MB.", "Ikke endret på lenge og større enn 10 MB.", "Sem alterações há muito tempo e com mais de 10 MB.", "Nemodificat de mult timp și mai mare de 10 MB.", "Inte ändrad på länge och större än 10 MB.", "ไม่มีการแก้ไขมานาน และมีขนาดใหญ่กว่า 10 MB", "Давно не змінювалися й більші за 10 МБ.", "Không sửa đổi trong thời gian dài và lớn hơn 10 MB."],
    "cleanup.explanation.duplicates": ["Идентично съдържание. Запазете едно копие и премахнете останалите.", "Shodný obsah. Ponechte jednu kopii a zbytek odstraňte.", "Identisk indhold. Behold én kopi, og fjern resten.", "Πανομοιότυπο περιεχόμενο. Κρατήστε ένα αντίγραφο και αφαιρέστε τα υπόλοιπα.", "Contenido idéntico. Conserva una copia y elimina el resto.", "Sama sisältö. Säilytä yksi kopio ja poista loput.", "Azonos tartalom. Tartson meg egy példányt, és távolítsa el a többit.", "Isinya identik. Simpan satu salinan dan hapus sisanya.", "Kandungannya serupa. Simpan satu salinan dan buang yang lain.", "Identisk innhold. Behold én kopi og fjern resten.", "Conteúdo idêntico. Mantenha uma cópia e elimine as restantes.", "Conținut identic. Păstrează o copie și elimină restul.", "Identiskt innehåll. Behåll en kopia och ta bort resten.", "เนื้อหาเหมือนกันทุกประการ เก็บไว้หนึ่งชุดและลบที่เหลือ", "Ідентичний вміст. Залиште одну копію, а решту видаліть.", "Nội dung giống hệt nhau. Giữ một bản và xóa các bản còn lại."],
    "cleanup.explanation.residue": ["Останали от приложение, което вече не е инсталирано.", "Zbylo po aplikaci, která už není nainstalovaná.", "Efterladt af en app, der ikke længere er installeret.", "Απέμειναν από εφαρμογή που δεν είναι πλέον εγκατεστημένη.", "Restos de una aplicación que ya no está instalada.", "Jäljellä sovelluksesta, jota ei ole enää asennettu.", "Egy már nem telepített alkalmazástól maradt vissza.", "Sisa dari aplikasi yang sudah tidak terpasang.", "Tinggalan daripada apl yang tidak lagi dipasang.", "Etterlatt av en app som ikke lenger er installert.", "Resíduo de uma aplicação que já não está instalada.", "Rămas de la o aplicație care nu mai este instalată.", "Kvar från en app som inte längre är installerad.", "ตกค้างจากแอปที่ถอนการติดตั้งไปแล้ว", "Залишилося від програми, яку вже не встановлено.", "Còn sót lại từ ứng dụng đã gỡ cài đặt."],
    "cleanup.explanation.residuePreferences": ["Файл с настройки без съответстващо инсталирано приложение.", "Soubor předvoleb bez odpovídající nainstalované aplikace.", "Indstillingsfil uden en matchende installeret app.", "Αρχείο προτιμήσεων χωρίς αντίστοιχη εγκατεστημένη εφαρμογή.", "Archivo de preferencias sin una aplicación instalada correspondiente.", "Asetustiedosto ilman vastaavaa asennettua sovellusta.", "Beállításfájl, amelyhez nincs telepített alkalmazás.", "File preferensi tanpa aplikasi terpasang yang cocok.", "Fail keutamaan tanpa apl dipasang yang sepadan.", "Innstillingfil uten en tilhørende installert app.", "Ficheiro de preferências sem uma aplicação instalada correspondente.", "Fișier de preferințe fără o aplicație instalată corespunzătoare.", "Inställningsfil utan en matchande installerad app.", "ไฟล์การตั้งค่าที่ไม่มีแอปที่ติดตั้งอยู่รองรับ", "Файл налаштувань без відповідної встановленої програми.", "Tệp tùy chọn không có ứng dụng nào đang cài khớp."],
    "cleanup.explanation.residueWebStorage": ["Уеб хранилище на приложение, което вече не е инсталирано.", "Webové úložiště po aplikaci, která už není nainstalovaná.", "Weblager for en app, der ikke længere er installeret.", "Δεδομένα web για εφαρμογή που δεν είναι πλέον εγκατεστημένη.", "Almacenamiento web de una aplicación que ya no está instalada.", "Verkkotallennus sovellukselle, jota ei ole enää asennettu.", "Webes tárhely egy már nem telepített alkalmazáshoz.", "Penyimpanan web untuk aplikasi yang sudah tidak terpasang.", "Storan web untuk apl yang tidak lagi dipasang.", "Weblagring for en app som ikke lenger er installert.", "Armazenamento web de uma aplicação que já não está instalada.", "Stocare web pentru o aplicație care nu mai este instalată.", "Webblagring för en app som inte längre är installerad.", "พื้นที่เก็บข้อมูลเว็บของแอปที่ถอนการติดตั้งไปแล้ว", "Вебсховище програми, яку вже не встановлено.", "Dữ liệu web của ứng dụng đã gỡ cài đặt."],
    "cleanup.explanation.residueGroupContainer": ["Споделен контейнер на приложение, което вече не е инсталирано.", "Sdílený kontejner aplikace, která už není nainstalovaná.", "Delt container for en app, der ikke længere er installeret.", "Κοινόχρηστο κοντέινερ εφαρμογής που δεν είναι πλέον εγκατεστημένη.", "Contenedor compartido de una aplicación que ya no está instalada.", "Jaettu säilö sovellukselle, jota ei ole enää asennettu.", "Egy már nem telepített alkalmazás megosztott konténere.", "Kontainer bersama milik aplikasi yang sudah tidak terpasang.", "Bekas kongsi bagi apl yang tidak lagi dipasang.", "Delt beholder for en app som ikke lenger er installert.", "Contentor partilhado de uma aplicação que já não está instalada.", "Container partajat al unei aplicații care nu mai este instalată.", "Delad container för en app som inte längre är installerad.", "คอนเทนเนอร์ที่ใช้ร่วมกันของแอปที่ถอนการติดตั้งไปแล้ว", "Спільний контейнер програми, яку вже не встановлено.", "Vùng chứa dùng chung của ứng dụng đã gỡ cài đặt."],
    "cleanup.explanation.savedState": ["Състояние на прозорците, запазено за приложения, които вече не работят.", "Stav oken uložený pro aplikace, které už neběží.", "Vinduestilstand gemt for apps, der ikke længere kører.", "Κατάσταση παραθύρων που έχει αποθηκευτεί για εφαρμογές που δεν εκτελούνται πλέον.", "Estado de ventanas guardado de aplicaciones que ya no están abiertas.", "Ikkunatila, joka on tallennettu sovelluksille, jotka eivät enää ole käynnissä.", "A már nem futó alkalmazásokhoz mentett ablakállapot.", "Status jendela yang disimpan untuk aplikasi yang sudah tidak berjalan.", "Keadaan tetingkap yang disimpan untuk apl yang tidak lagi berjalan.", "Vindustilstand lagret for apper som ikke lenger kjører.", "Estado das janelas guardado para aplicações que já não estão em execução.", "Starea ferestrelor salvată pentru aplicații care nu mai rulează.", "Fönstertillstånd sparat för appar som inte längre körs.", "สถานะหน้าต่างที่บันทึกไว้สำหรับแอปที่ไม่ได้ทำงานอยู่แล้ว", "Стан вікон, збережений для програм, які вже не працюють.", "Trạng thái cửa sổ được lưu cho ứng dụng không còn chạy."],
    "risk.safe.short": ["Безопасно", "Bezpečné", "Sikker", "Ασφαλές", "Seguro", "Turvallinen", "Biztonságos", "Aman", "Selamat", "Trygg", "Seguro", "Sigur", "Säker", "ปลอดภัย", "Безпечно", "An toàn"],
    "risk.review.short": ["Преглед", "Ke kontrole", "Gennemse", "Έλεγχος", "Revisar", "Tarkista", "Átnézendő", "Tinjau", "Semak", "Gjennomgå", "Rever", "De verificat", "Granska", "ควรตรวจสอบ", "Перевірити", "Xem lại"],
    "risk.protected.short": ["Защитено", "Chráněné", "Beskyttet", "Προστατευμένο", "Protegido", "Suojattu", "Védett", "Dilindungi", "Dilindungi", "Beskyttet", "Protegido", "Protejat", "Skyddad", "ป้องกันอยู่", "Захищено", "Được bảo vệ"],
    "risk.safe.detail": ["Създават се отново автоматично при нужда. Избрано по подразбиране.", "V případě potřeby se vytvoří znovu. Ve výchozím nastavení vybráno.", "Genskabes automatisk efter behov. Valgt som standard.", "Δημιουργείται ξανά αυτόματα αν χρειαστεί. Επιλεγμένο από προεπιλογή.", "Se regenera automáticamente si es necesario. Seleccionado por defecto.", "Luodaan tarvittaessa automaattisesti uudelleen. Valittu oletuksena.", "Szükség esetén automatikusan újraépül. Alapértelmezés szerint kijelölve.", "Dibangun ulang otomatis jika perlu. Dipilih secara default.", "Dibina semula secara automatik jika perlu. Dipilih secara lalai.", "Bygges automatisk på nytt ved behov. Valgt som standard.", "Recriado automaticamente se necessário. Selecionado por predefinição.", "Se recreează automat dacă este nevoie. Selectat implicit.", "Byggs upp automatiskt vid behov. Markerad som standard.", "สร้างใหม่โดยอัตโนมัติหากจำเป็น เลือกไว้เป็นค่าเริ่มต้น", "Створюються заново за потреби. Вибрано за замовчуванням.", "Được tạo lại tự động nếu cần. Được chọn mặc định."],
    "risk.review.detail": ["Обикновено е безопасно за премахване, но е добре да потвърдите.", "Obvykle je bezpečné odstranit, ale měli byste to potvrdit.", "Normalt sikkert at fjerne, men bekræft det.", "Συνήθως είναι ασφαλές για αφαίρεση, αλλά καλό είναι να το επιβεβαιώσετε.", "Normalmente se puede eliminar, pero conviene confirmar.", "Yleensä turvallista poistaa, mutta vahvista.", "Általában biztonságosan eltávolítható, de erősítse meg.", "Biasanya aman dihapus, tetapi sebaiknya Anda konfirmasi.", "Biasanya selamat untuk dibuang, tetapi anda harus mengesahkannya.", "Vanligvis trygt å fjerne, men du bør bekrefte.", "Normalmente pode ser eliminado, mas deve confirmar.", "De obicei poate fi eliminat în siguranță, dar ar trebui să confirmi.", "Oftast säkert att ta bort, men du bör bekräfta.", "โดยปกติลบได้อย่างปลอดภัย แต่คุณควรยืนยัน", "Зазвичай безпечно видаляти, але варто підтвердити.", "Thường an toàn để xóa nhưng bạn nên xác nhận."],
    "risk.protected.detail": ["Sift няма да премахне това. Показано е само за информация.", "Sift toto neodstraní. Zobrazuje se pouze pro informaci.", "Sift fjerner ikke dette. Det vises kun som information.", "Το Sift δεν θα το αφαιρέσει. Εμφανίζεται μόνο ενημερωτικά.", "Sift no elimina esto. Solo se muestra a modo informativo.", "Sift ei poista tätä. Se näytetään vain tiedoksi.", "A Sift nem távolítja el. Csak tájékoztatásul jelenik meg.", "Sift tidak akan menghapusnya. Ini hanya ditampilkan sebagai informasi.", "Sift tidak akan membuangnya. Ia dipaparkan untuk maklumat sahaja.", "Sift fjerner ikke dette. Det vises bare som informasjon.", "O Sift não elimina isto. É apresentado apenas a título informativo.", "Sift nu va elimina acest element. Este afișat doar pentru informare.", "Sift tar inte bort detta. Det visas endast som information.", "Sift จะไม่ลบรายการนี้ แสดงไว้เพื่อเป็นข้อมูลเท่านั้น", "Sift не видалить це. Показано лише для інформації.", "Sift sẽ không xóa mục này. Mục chỉ được hiển thị để tham khảo."],
    "cleanup.confirm.title": ["Да се премести в Кошчето?", "Přesunout do Koše?", "Flyt til Papirkurven?", "Μετακίνηση στον Κάδο;", "¿Mover a la Papelera?", "Siirretäänkö Roskakoriin?", "Áthelyezi a Kukába?", "Pindahkan ke Tempat Sampah?", "Alih ke Tong Sampah?", "Flytte til Papirkurven?", "Mover para o Lixo?", "Mut în Coș?", "Flytta till Papperskorgen?", "ย้ายไปที่ถังขยะหรือไม่", "Перемістити в Кошик?", "Chuyển vào Thùng rác?"],
    "cleanup.confirm.moveCount": ["Преместване на %d елемента в Кошчето, общо %@", "Přesunout %d položek do Koše, celkem %@", "Flyt %d elementer til Papirkurven, %@ i alt", "Μετακίνηση %d στοιχείων στον Κάδο, %@ συνολικά", "Mover %d elementos a la Papelera, %@ en total", "Siirrä %d kohdetta Roskakoriin, yhteensä %@", "%d elem áthelyezése a Kukába, összesen %@", "Pindahkan %d item ke Tempat Sampah, total %@", "Alihkan %d item ke Tong Sampah, jumlah %@", "Flytt %d elementer til Papirkurven, %@ totalt", "Mover %d itens para o Lixo, %@ no total", "Mută %d elemente în Coș, %@ în total", "Flytta %d objekt till Papperskorgen, %@ totalt", "ย้าย %d รายการไปที่ถังขยะ รวม %@", "Перемістити %d елементів у Кошик, загалом %@", "Chuyển %d mục vào Thùng rác, tổng cộng %@"],
    "cleanup.confirm.moveCountOne": ["Преместване на 1 елемент в Кошчето, общо %@", "Přesunout 1 položku do Koše, celkem %@", "Flyt 1 element til Papirkurven, %@ i alt", "Μετακίνηση 1 στοιχείου στον Κάδο, %@ συνολικά", "Mover 1 elemento a la Papelera, %@ en total", "Siirrä 1 kohde Roskakoriin, yhteensä %@", "1 elem áthelyezése a Kukába, összesen %@", "Pindahkan 1 item ke Tempat Sampah, total %@", "Alihkan 1 item ke Tong Sampah, jumlah %@", "Flytt 1 element til Papirkurven, %@ totalt", "Mover 1 item para o Lixo, %@ no total", "Mută 1 element în Coș, %@ în total", "Flytta 1 objekt till Papperskorgen, %@ totalt", "ย้าย 1 รายการไปที่ถังขยะ รวม %@", "Перемістити 1 елемент у Кошик, загалом %@", "Chuyển 1 mục vào Thùng rác, tổng cộng %@"],
    "cleanup.confirm.undoNotice": ["Всичко отива в Кошчето, така че можете да го върнете, докато не го изпразните.", "Vše jde do Koše, takže můžete vše vrátit, dokud jej nevysypete.", "Alt ryger i Papirkurven, så du kan lægge det tilbage, indtil du tømmer den.", "Όλα πηγαίνουν στον Κάδο, ώστε να μπορείτε να τα επαναφέρετε μέχρι να τον αδειάσετε.", "Todo va a la Papelera, así que puedes recuperarlo hasta que la vacíes.", "Kaikki siirtyy Roskakoriin, joten voit palauttaa ne, kunnes tyhjennät sen.", "Minden a Kukába kerül, így visszateheti, amíg ki nem üríti.", "Semua dipindahkan ke Tempat Sampah, jadi Anda dapat mengembalikannya sampai Anda mengosongkannya.", "Semuanya masuk ke Tong Sampah, jadi anda boleh mengembalikannya sehingga anda mengosongkannya.", "Alt går til Papirkurven, så du kan legge det tilbake til du tømmer den.", "Tudo vai para o Lixo, pelo que pode recuperar os itens até o esvaziar.", "Totul ajunge în Coș, așa că poți pune la loc până îl golești.", "Allt hamnar i Papperskorgen, så du kan lägga tillbaka det tills du tömmer den.", "ทุกอย่างจะถูกย้ายไปที่ถังขยะ คุณจึงกู้คืนได้จนกว่าจะล้างถังขยะ", "Усе переміщується в Кошик, тож ви можете повернути це, доки не спорожните його.", "Mọi thứ đều được chuyển vào Thùng rác, bạn có thể khôi phục cho đến khi làm trống Thùng rác."],
    "cleanup.confirm.selectedItems": ["Избрани: %d", "Vybráno: %d", "%d valgt", "%d επιλεγμένα", "%d seleccionados", "%d valittu", "%d kijelölve", "%d dipilih", "%d dipilih", "%d valgt", "%d selecionados", "Selectate: %d", "%d markerade", "เลือกแล้ว %d รายการ", "Вибрано: %d", "Đã chọn %d"],
    "cleanup.confirm.methodValue": ["Преместване в Кошчето (може да се върне)", "Přesun do Koše (lze obnovit)", "Flyt til Papirkurven (kan gendannes)", "Μετακίνηση στον Κάδο (ανακτήσιμο)", "Mover a la Papelera (recuperable)", "Siirrä Roskakoriin (palautettavissa)", "Áthelyezés a Kukába (visszaállítható)", "Pindahkan ke Tempat Sampah (dapat dipulihkan)", "Alih ke Tong Sampah (boleh dipulihkan)", "Flytt til Papirkurven (kan gjenopprettes)", "Mover para o Lixo (recuperável)", "Mutare în Coș (recuperabil)", "Flytta till Papperskorgen (kan återställas)", "ย้ายไปที่ถังขยะ (กู้คืนได้)", "Переміщення в Кошик (можна повернути)", "Chuyển vào Thùng rác (có thể khôi phục)"],
    "cleanup.confirm.cancel": ["Отказ", "Zrušit", "Annuller", "Ακύρωση", "Cancelar", "Peruuta", "Mégse", "Batal", "Batal", "Avbryt", "Cancelar", "Anulează", "Avbryt", "ยกเลิก", "Скасувати", "Hủy"],
    "cleanup.confirm.skipConfirmation": ["Да не се пита следващия път", "Příště potvrzení přeskočit", "Spring bekræftelse over næste gang", "Παράλειψη επιβεβαίωσης την επόμενη φορά", "Omitir la confirmación la próxima vez", "Ohita vahvistus seuraavalla kerralla", "Legközelebb hagyja ki a megerősítést", "Lewati konfirmasi lain kali", "Langkau pengesahan lain kali", "Hopp over bekreftelse neste gang", "Ignorar a confirmação da próxima vez", "Omite confirmarea data viitoare", "Hoppa över bekräftelse nästa gång", "ข้ามการยืนยันในครั้งถัดไป", "Не питати наступного разу", "Bỏ qua xác nhận lần sau"],
    "cleanup.confirm.riskWarning": ["Включили сте елементи, отбелязани за преглед. Проверете списъка, преди да продължите.", "Zahrnuli jste položky označené ke kontrole. Před pokračováním zkontrolujte seznam.", "Du har medtaget elementer markeret til gennemgang. Kontroller listen, før du fortsætter.", "Έχετε συμπεριλάβει στοιχεία που έχουν χαρακτηριστεί προς έλεγχο. Ελέγξτε τη λίστα πριν συνεχίσετε.", "Incluiste elementos marcados para revisar. Revisa la lista antes de continuar.", "Olet valinnut kohteita, jotka on merkitty tarkistettaviksi. Tarkista luettelo ennen jatkamista.", "Átnézendőnek jelölt elemeket is kijelölt. Kérjük, ellenőrizze a listát, mielőtt folytatja.", "Anda menyertakan item yang ditandai untuk ditinjau. Periksa daftar sebelum melanjutkan.", "Anda telah menyertakan item yang ditanda untuk disemak. Sila semak senarai sebelum meneruskan.", "Du har tatt med elementer merket for gjennomgang. Kontroller listen før du fortsetter.", "Incluiu itens marcados para revisão. Verifique a lista antes de continuar.", "Ai inclus elemente marcate pentru verificare. Verifică lista înainte de a continua.", "Du har inkluderat objekt markerade för granskning. Kontrollera listan innan du fortsätter.", "คุณได้เลือกรายการที่ทำเครื่องหมายว่าควรตรวจสอบ โปรดตรวจสอบรายการก่อนดำเนินการต่อ", "Ви включили елементи, позначені для перевірки. Перегляньте список, перш ніж продовжити.", "Bạn đã bao gồm các mục được đánh dấu cần xem lại. Vui lòng kiểm tra danh sách trước khi tiếp tục."],
    "cleanup.result.title": ["Почистването е завършено", "Čištění dokončeno", "Oprydning fuldført", "Ο καθαρισμός ολοκληρώθηκε", "Limpieza finalizada", "Siivous valmis", "Tisztítás befejezve", "Pembersihan selesai", "Pembersihan selesai", "Opprydding fullført", "Limpeza concluída", "Curățare finalizată", "Rensning klar", "ทำความสะอาดเสร็จแล้ว", "Очищення завершено", "Dọn dẹp xong"],
    "cleanup.result.moved": ["Преместени в Кошчето: %d елемента", "Položky přesunuty do Koše: %d", "%d elementer flyttet til Papirkurven", "%d στοιχεία μετακινήθηκαν στον Κάδο", "%d elementos movidos a la Papelera", "%d kohdetta siirretty Roskakoriin", "%d elem áthelyezve a Kukába", "%d item dipindahkan ke Tempat Sampah", "%d item dialihkan ke Tong Sampah", "%d elementer flyttet til Papirkurven", "%d itens movidos para o Lixo", "Elemente mutate în Coș: %d", "%d objekt flyttade till Papperskorgen", "ย้าย %d รายการไปที่ถังขยะแล้ว", "Переміщено в Кошик: %d елементів", "Đã chuyển %d mục vào Thùng rác"],
    "cleanup.result.released": ["Освободени %@", "Uvolněno %@", "Frigjorde %@", "Ελευθερώθηκαν %@", "Liberados %@", "Vapautettiin %@", "%@ felszabadítva", "Membebaskan %@", "Melepaskan %@", "Frigjorde %@", "Libertado %@", "S-a eliberat %@", "Frigjorde %@", "ปลดปล่อยไป %@", "Звільнено %@", "Đã giải phóng %@"],
    "cleanup.result.showTrash": ["Покажете Кошчето в Finder", "Zobrazit Koš ve Finderu", "Vis Papirkurven i Finder", "Εμφάνιση Κάδου στο Finder", "Mostrar la Papelera en el Finder", "Näytä Roskakori Finderissä", "Kuka megjelenítése a Finderben", "Tampilkan Tempat Sampah di Finder", "Tunjukkan Tong Sampah dalam Finder", "Vis Papirkurven i Finder", "Mostrar o Lixo no Finder", "Arată Coșul în Finder", "Visa Papperskorgen i Finder", "แสดงถังขยะใน Finder", "Показати Кошик у Finder", "Hiện Thùng rác trong Finder"],
    "cleanup.result.undoHint": ["Върнете елементите от Кошчето, докато не го изпразните.", "Položky můžete z Koše vrátit, dokud jej nevysypete.", "Læg elementer tilbage fra Papirkurven, indtil du tømmer den.", "Επαναφέρετε τα στοιχεία από τον Κάδο μέχρι να τον αδειάσετε.", "Recupera los elementos de la Papelera mientras no la vacíes.", "Palauta kohteita Roskakorista, kunnes tyhjennät sen.", "Tegye vissza az elemeket a Kukából, amíg ki nem üríti.", "Kembalikan item dari Tempat Sampah sampai Anda mengosongkannya.", "Pulangkan item daripada Tong Sampah sehingga anda mengosongkannya.", "Legg elementer tilbake fra Papirkurven til du tømmer den.", "Recupere os itens do Lixo até o esvaziar.", "Pune elementele la loc din Coș până îl golești.", "Lägg tillbaka objekt från Papperskorgen tills du tömmer den.", "นำรายการกลับคืนได้จากถังขยะจนกว่าจะล้างถังขยะ", "Поверніть елементи з Кошика, доки не спорожнили його.", "Khôi phục các mục từ Thùng rác cho đến khi làm trống Thùng rác."],
    "cleanup.result.details": ["Подробности за елементите", "Podrobnosti položek", "Elementdetaljer", "Λεπτομέρειες στοιχείων", "Detalles de los elementos", "Kohteen tiedot", "Elem részletei", "Detail item", "Butiran item", "Elementdetaljer", "Detalhes dos itens", "Detalii elemente", "Objektdetaljer", "รายละเอียดรายการ", "Деталі елементів", "Chi tiết mục"],
    "cleanup.result.exportReport": ["Експортирайте отчета като PDF", "Exportovat zprávu jako PDF", "Eksporter rapport som PDF", "Εξαγωγή αναφοράς ως PDF", "Exportar informe en PDF", "Vie raportti PDF:nä", "Jelentés exportálása PDF-ként", "Ekspor laporan sebagai PDF", "Eksport laporan sebagai PDF", "Eksporter rapport som PDF", "Exportar relatório em PDF", "Exportă raportul ca PDF", "Exportera rapport som PDF", "ส่งออกรายงานเป็น PDF", "Експортувати звіт у PDF", "Xuất báo cáo dạng PDF"],
    "cleanup.failure.permissionDenied": ["Нужен е достъп до диска", "Je potřeba přístup k disku", "Kræver diskadgang", "Χρειάζεται πρόσβαση στον δίσκο", "Necesita acceso al disco", "Tarvitsee levynkäyttöoikeuden", "Lemezhozzáférés kell", "Perlu akses disk", "Perlu akses cakera", "Trenger disktilgang", "Requer acesso ao disco", "Necesită acces la disc", "Kräver skivåtkomst", "ต้องใช้สิทธิ์เข้าถึงดิสก์", "Потрібен доступ до диска", "Cần quyền truy cập đĩa"],
    "cleanup.failure.fileNotFound": ["Вече е премахнат", "Již odstraněno", "Allerede fjernet", "Έχει ήδη αφαιρεθεί", "Ya eliminado", "Jo poistettu", "Már eltávolítva", "Sudah dihapus", "Sudah dibuang", "Allerede fjernet", "Já eliminado", "Deja eliminat", "Redan borttagna", "ถูกลบไปแล้ว", "Уже видалено", "Đã bị xóa"],
    "cleanup.failure.fileInUse": ["Използва се, пропуснат", "Používá se, přeskočeno", "I brug, sprunget over", "Σε χρήση, παραλείφθηκε", "En uso, omitido", "Käytössä, ohitettu", "Használatban, kihagyva", "Sedang digunakan, dilewati", "Sedang digunakan, dilangkau", "I bruk, hoppet over", "Em utilização, ignorado", "În uz, ignorat", "Används, överhoppad", "ถูกใช้งานอยู่ ข้ามไป", "Використовується, пропущено", "Đang được dùng, bỏ qua"],
    "cleanup.failure.itemChanged": ["Променен, пропуснат", "Změněno, přeskočeno", "Ændret, sprunget over", "Άλλαξε, παραλείφθηκε", "Cambió, omitido", "Muuttunut, ohitettu", "Módosult, kihagyva", "Berubah, dilewati", "Berubah, dilangkau", "Endret, hoppet over", "Alterado, ignorado", "Modificat, ignorat", "Ändrad, överhoppad", "เปลี่ยนแปลงแล้ว ข้ามไป", "Змінено, пропущено", "Đã thay đổi, bỏ qua"],
    "cleanup.failure.volumeUnavailable": ["Дискът е изключен", "Disk odpojen", "Disken er afbrudt", "Ο δίσκος αποσυνδέθηκε", "Disco desconectado", "Levy on irrotettu", "Lemez leválasztva", "Disk terputus", "Cakera diputuskan", "Disken er koblet fra", "Disco desligado", "Disc deconectat", "Disken är frånkopplad", "ดิสก์ถูกตัดการเชื่อมต่อ", "Диск від'єднано", "Đĩa đã ngắt kết nối"],
    "cleanup.failure.protectedLocation": ["Защитено място", "Chráněné místo", "Beskyttet placering", "Προστατευμένη τοποθεσία", "Ubicación protegida", "Suojattu sijainti", "Védett hely", "Lokasi yang dilindungi", "Lokasi dilindungi", "Beskyttet sted", "Local protegido", "Locație protejată", "Skyddad plats", "ตำแหน่งที่ได้รับการป้องกัน", "Захищене місце", "Vị trí được bảo vệ"],
    "cleanup.failure.partialFailure": ["Частично изпълнено", "Částečně hotovo", "Delvist udført", "Έγινε εν μέρει", "Hecho en parte", "Osittain valmis", "Részben kész", "Selesai sebagian", "Selesai sebahagian", "Delvis fullført", "Concluído em parte", "Parțial finalizat", "Delvis slutfört", "เสร็จบางส่วน", "Виконано частково", "Hoàn thành một phần"],
    "uninstall.search": ["Търсене на приложения", "Hledat aplikace", "Søg efter apps", "Αναζήτηση εφαρμογών", "Buscar aplicaciones", "Hae sovelluksia", "Alkalmazások keresése", "Cari aplikasi", "Cari apl", "Søk etter apper", "Pesquisar aplicações", "Caută aplicații", "Sök appar", "ค้นหาแอป", "Пошук програм", "Tìm ứng dụng"],
    "uninstall.sort.name": ["Име", "Název", "Navn", "Όνομα", "Nombre", "Nimi", "Név", "Nama", "Nama", "Navn", "Nome", "Nume", "Namn", "ชื่อ", "Назва", "Tên"],
    "uninstall.sort.size": ["Размер", "Velikost", "Størrelse", "Μέγεθος", "Tamaño", "Koko", "Méret", "Ukuran", "Saiz", "Størrelse", "Tamanho", "Dimensiune", "Storlek", "ขนาด", "Розмір", "Kích thước"],
    "uninstall.sort.lastUsed": ["Последно използване", "Naposledy použito", "Senest brugt", "Τελευταία χρήση", "Último uso", "Viimeksi käytetty", "Utolsó használat", "Terakhir digunakan", "Terakhir digunakan", "Sist brukt", "Última utilização", "Ultima utilizare", "Senast använd", "ใช้ล่าสุด", "Останнє використання", "Dùng gần đây"],
    "uninstall.noneInstalled": ["Не са намерени приложения от трети страни", "Nenalezeny žádné aplikace třetích stran", "Ingen tredjepartsapps fundet", "Δεν βρέθηκαν εφαρμογές τρίτων", "No se encontraron aplicaciones de terceros", "Kolmannen osapuolen sovelluksia ei löytynyt", "Nem találhatók harmadik féltől származó alkalmazások", "Tidak ada aplikasi pihak ketiga yang ditemukan", "Tiada apl pihak ketiga ditemui", "Ingen tredjepartsapper funnet", "Não foram encontradas aplicações de terceiros", "Nu s-au găsit aplicații terțe", "Inga tredjepartsappar hittades", "ไม่พบแอปของบุคคลที่สาม", "Сторонніх програм не знайдено", "Không tìm thấy ứng dụng bên thứ ba"],
    "uninstall.systemApp": ["Не може да се деинсталира", "Nelze odinstalovat", "Kan ikke afinstalleres", "Δεν είναι δυνατή η απεγκατάσταση", "No se puede desinstalar", "Ei voi poistaa asennusta", "Nem távolítható el", "Tidak dapat dihapus", "Tidak boleh dinyahpasang", "Kan ikke avinstalleres", "Não pode ser desinstalada", "Nu poate fi dezinstalată", "Kan inte avinstalleras", "ถอนการติดตั้งไม่ได้", "Не можна видалити", "Không thể gỡ cài đặt"],
    "uninstall.systemAppDetail": ["Sift премахва само приложения, които вие сте инсталирали.", "Sift odstraňuje pouze aplikace, které jste nainstalovali sami.", "Sift fjerner kun apps, du selv har installeret.", "Το Sift αφαιρεί μόνο εφαρμογές που εγκαταστήσατε εσείς.", "Sift solo elimina las aplicaciones que instalaste tú.", "Sift poistaa vain itse asentamiasi sovelluksia.", "A Sift csak az Ön által telepített alkalmazásokat távolítja el.", "Sift hanya menghapus aplikasi yang Anda pasang sendiri.", "Sift hanya membuang apl yang anda pasang sendiri.", "Sift fjerner bare apper du har installert selv.", "O Sift só elimina aplicações que instalou.", "Sift elimină doar aplicațiile pe care le-ai instalat singur.", "Sift tar bara bort appar som du själv har installerat.", "Sift จะลบเฉพาะแอปที่คุณติดตั้งเองเท่านั้น", "Sift видаляє лише програми, які ви встановили самостійно.", "Sift chỉ gỡ các ứng dụng do bạn tự cài."],
    "uninstall.needsReview": ["Изискват вашето потвърждение", "Vyžaduje vaše potvrzení", "Kræver din bekræftelse", "Χρειάζονται την επιβεβαίωσή σας", "Necesitan tu confirmación", "Vaatii vahvistuksesi", "Az Ön megerősítését igényli", "Memerlukan konfirmasi Anda", "Memerlukan pengesahan anda", "Trenger din bekreftelse", "Necessitam da sua confirmação", "Necesită confirmarea ta", "Behöver din bekräftelse", "ต้องได้รับการยืนยันจากคุณ", "Потребують вашого підтвердження", "Cần bạn xác nhận"],
    "uninstall.reason.bundleIdentifier": ["Името е идентификаторът на това приложение.", "Název je identifikátor balíčku této aplikace.", "Navnet er denne apps bundle-id.", "Το όνομα είναι το αναγνωριστικό bundle αυτής της εφαρμογής.", "El nombre es el identificador del paquete de esta aplicación.", "Nimi on tämän sovelluksen bundle-tunniste.", "A név ennek az alkalmazásnak a csomóazonosítója.", "Nama tersebut adalah pengenal bundle aplikasi ini.", "Nama itu ialah pengecam bundel apl ini.", "Navnet er denne appens bundle-ID.", "O nome é o identificador do pacote desta aplicação.", "Numele este identificatorul de pachet al acestei aplicații.", "Namnet är appens bundle-ID.", "ชื่อนี้คือ bundle identifier ของแอปนี้", "Назва — це ідентифікатор пакета цієї програми.", "Tên chính là bundle identifier của ứng dụng này."],
    "uninstall.reason.identifierPrefix": ["Името започва с идентификатора на това приложение.", "Název začíná identifikátorem balíčku této aplikace.", "Navnet begynder med denne apps bundle-id.", "Το όνομα ξεκινά με το αναγνωριστικό bundle αυτής της εφαρμογής.", "El nombre empieza por el identificador del paquete de esta aplicación.", "Nimi alkaa tämän sovelluksen bundle-tunnisteella.", "A név ennek az alkalmazásnak a csomóazonosítójával kezdődik.", "Nama dimulai dengan pengenal bundle aplikasi ini.", "Nama bermula dengan pengecam bundel apl ini.", "Navnet begynner med denne appens bundle-ID.", "O nome começa pelo identificador do pacote desta aplicação.", "Numele începe cu identificatorul de pachet al acestei aplicații.", "Namnet börjar med appens bundle-ID.", "ชื่อนี้ขึ้นต้นด้วย bundle identifier ของแอปนี้", "Назва починається з ідентифікатора пакета цієї програми.", "Tên bắt đầu bằng bundle identifier của ứng dụng này."],
    "uninstall.reason.applicationName": ["Името е точно името на приложението, в папка, която macOS пази за всяко приложение.", "Název je přesně název aplikace ve složce, kterou macOS vede pro každou aplikaci.", "Navnet er præcis appnavnet i en mappe, som macOS holder per app.", "Το όνομα είναι ακριβώς το όνομα της εφαρμογής, σε φάκελο που το macOS κρατά για κάθε εφαρμογή.", "El nombre coincide exactamente con el de la aplicación, en una carpeta que macOS mantiene por aplicación.", "Nimi on täsmälleen sovelluksen nimi kansiossa, jota macOS pitää sovelluskohtaisesti.", "A név pontosan az alkalmazás neve, egy macOS által alkalmazásonként fenntartott mappában.", "Nama persis sama dengan nama aplikasi, dalam folder yang macOS sediakan per aplikasi.", "Nama itu tepat sama dengan nama aplikasi, dalam folder yang macOS sediakan bagi setiap apl.", "Navnet er nøyaktig appnavnet, i en mappe macOS holder per app.", "O nome coincide exatamente com o da aplicação, numa pasta que o macOS mantém por aplicação.", "Numele este exact numele aplicației, într-un folder pe care macOS îl păstrează pentru fiecare aplicație.", "Namnet är exakt appnamnet, i en mapp som macOS håller per app.", "ชื่อนี้ตรงกับชื่อแอปทุกประการ ในโฟลเดอร์ที่ macOS เก็บแยกตามแอป", "Назва точно збігається з назвою програми в папці, яку macOS веде для кожної програми.", "Tên trùng khớp chính xác với tên ứng dụng, trong thư mục mà macOS lưu riêng cho từng ứng dụng."],
    "uninstall.reason.identifierSuffix": ["Името съвпада с последната част от идентификатора на това приложение.", "Název odpovídá poslední části identifikátoru balíčku této aplikace.", "Navnet matcher den sidste del af denne apps bundle-id.", "Το όνομα αντιστοιχεί στο τελευταίο τμήμα του αναγνωριστικού bundle αυτής της εφαρμογής.", "El nombre coincide con la última parte del identificador del paquete de esta aplicación.", "Nimi vastaa tämän sovelluksen bundle-tunnisteen viimeistä osaa.", "A név ennek az alkalmazásnak a csomóazonosítója utolsó részével egyezik.", "Nama cocok dengan bagian akhir pengenal bundle aplikasi ini.", "Nama sepadan dengan bahagian akhir pengecam bundel apl ini.", "Navnet samsvarer med den siste delen av denne appens bundle-ID.", "O nome corresponde à última parte do identificador do pacote desta aplicação.", "Numele corespunde ultimei părți a identificatorului de pachet al acestei aplicații.", "Namnet matchar den sista delen av appens bundle-ID.", "ชื่อนี้ตรงกับส่วนท้ายของ bundle identifier ของแอปนี้", "Назва збігається з останньою частиною ідентифікатора пакета цієї програми.", "Tên khớp với phần cuối của bundle identifier của ứng dụng này."],
    "uninstall.reason.appGroup": ["Контейнерът принадлежи на група приложения, декларирана от това приложение.", "Kontejner patří do skupiny aplikací, kterou tato aplikace deklaruje.", "Beholderen tilhører en appgruppe, som denne app erklærer.", "Ο περιέκτης ανήκει σε ομάδα εφαρμογών που δηλώνει αυτή η εφαρμογή.", "El contenedor pertenece a un grupo de apps declarado por esta app.", "Säilö kuuluu sovellusryhmään, jonka tämä sovellus ilmoittaa.", "A tároló egy olyan alkalmazáscsoporthoz tartozik, amelyet ez az alkalmazás deklarál.", "Kontainer milik grup app yang dideklarasikan oleh app ini.", "Kontainer milik kumpulan app yang diisytiharkan oleh app ini.", "Beholderen tilhører en appgruppe som denne appen erklærer.", "O contentor pertence a um grupo de apps declarado por esta app.", "Containerul aparține unui grup de aplicații declarat de această aplicație.", "Behållaren tillhör en appgrupp som den här appen deklarerar.", "คอนเทนเนอร์อยู่ในกลุ่มแอปที่แอปนี้ประกาศ", "Контейнер належить до групи програм, яку оголошує ця програма.", "Vùng chứa thuộc một nhóm ứng dụng mà ứng dụng này khai báo."],
    "uninstall.copyGroupIdentifier": ["Копиране на идентификатора на групата", "Kopírovat identifikátor skupiny", "Kopiér gruppeidentifikator", "Αντιγραφή αναγνωριστικού ομάδας", "Copiar identificador del grupo", "Kopioi ryhmätunniste", "Csoportazonosító másolása", "Salin pengenal grup", "Salin pengecam kumpulan", "Kopier gruppeidentifikator", "Copiar identificador do grupo", "Copiază identificatorul grupului", "Kopiera gruppidentifierare", "คัดลอกตัวระบุกลุ่ม", "Копіювати ідентифікатор групи", "Sao chép mã định danh nhóm"],
    "uninstall.appRunning": ["%@ работи. Затворете го преди премахване, иначе Sift ще пропусне файловете, които държи отворени.", "%@ je spuštěna. Před odstraněním ji ukončete, jinak Sift vynechá soubory, které drží otevřené.", "%@ kører. Afslut det, før du fjerner det; ellers springer Sift de filer over, det holder åbne.", "Η εφαρμογή %@ εκτελείται. Κλείστε την πριν από την αφαίρεση, αλλιώς το Sift θα παραλείψει τα αρχεία που κρατά ανοιχτά.", "%@ está en ejecución. Ciérrala antes de eliminar, o Sift omitirá los archivos que mantiene abiertos.", "%@ on käynnissä. Lopeta se ennen poistamista, muuten Sift ohittaa tiedostot, jotka se pitää avoinna.", "%@ fut. Az eltávolítás előtt lépjen ki belőle, különben a Sift kihagyja a nyitva tartott fájlokat.", "%@ sedang berjalan. Keluar darinya sebelum menghapus, atau Sift akan melewati file yang sedang dibukanya.", "%@ sedang berjalan. Keluar daripadanya sebelum membuang, atau Sift akan melangkau fail yang dibukanya.", "%@ kjører. Avslutt det før du fjerner, ellers hopper Sift over filene det holder åpne.", "%@ está em execução. Encerre-a antes de eliminar, ou o Sift irá ignorar os ficheiros que mantém abertos.", "%@ rulează. Închide-o înainte de eliminare, altfel Sift va sări peste fișierele pe care le ține deschise.", "%@ körs. Avsluta det innan du tar bort det, annars hoppar Sift över filerna det håller öppna.", "%@ กำลังทำงาน โปรดปิดก่อนลบ ไม่เช่นนั้น Sift จะข้ามไฟล์ที่แอปเปิดอยู่", "%@ працює. Закрийте його перед видаленням, інакше Sift пропустить файли, які воно тримає відкритими.", "%@ đang chạy. Hãy thoát ứng dụng trước khi gỡ, nếu không Sift sẽ bỏ qua các tệp đang được mở."],
    "uninstall.quitFailed": ["Sift не можа да помоли %@ да се затвори. Затворете го ръчно и опитайте отново.", "Sift nemohl požádat %@ o ukončení. Ukončete ji ručně a zkuste to znovu.", "Sift kunne ikke bede %@ om at afslutte. Afslut det manuelt, og prøv igen.", "Το Sift δεν μπόρεσε να ζητήσει από την εφαρμογή %@ να κλείσει. Κλείστε την χειροκίνητα και δοκιμάστε ξανά.", "Sift no pudo pedir a %@ que se cerrara. Ciérrala manualmente e inténtalo de nuevo.", "Sift ei voinut pyytää sovellusta %@ lopettamaan. Lopeta se manuaalisesti ja yritä uudelleen.", "A Sift nem tudta kilépésre kérni a következőt: %@. Lépjen ki manuálisan, és próbálja újra.", "Sift tidak dapat meminta %@ untuk keluar. Keluar secara manual lalu coba lagi.", "Sift tidak dapat meminta %@ keluar. Keluar secara manual dan cuba lagi.", "Sift kunne ikke be %@ om å avslutte. Avslutt det manuelt og prøv igjen.", "O Sift não conseguiu pedir a %@ que encerrasse. Encerre-a manualmente e tente novamente.", "Sift nu a putut cere închiderea %@. Închide-o manual și încearcă din nou.", "Sift kunde inte be %@ att avsluta. Avsluta det manuellt och försök igen.", "Sift ไม่สามารถขอให้ %@ ปิดได้ โปรดปิดด้วยตัวเองแล้วลองอีกครั้ง", "Sift не вдалося попросити %@ закритися. Закрийте його вручну й повторіть.", "Sift không thể yêu cầu %@ thoát. Hãy thoát thủ công rồi thử lại."],
    "uninstall.noRelatedFiles": ["Не са намерени свързани файлове.", "Nebyly nalezeny žádné související soubory.", "Ingen relaterede filer blev fundet.", "Δεν βρέθηκαν σχετικά αρχεία.", "No se encontraron archivos relacionados.", "Liittyviä tiedostoja ei löytynyt.", "Nem találhatók kapcsolódó fájlok.", "Tidak ada file terkait yang ditemukan.", "Tiada fail berkaitan ditemui.", "Ingen tilknyttede filer ble funnet.", "Não foram encontrados ficheiros relacionados.", "Nu s-au găsit fișiere asociate.", "Inga relaterade filer hittades.", "ไม่พบไฟล์ที่เกี่ยวข้อง", "Пов'язаних файлів не знайдено.", "Không tìm thấy tệp liên quan."],
    "uninstall.selectApp": ["Изберете приложение, за да видите какво ще бъде премахнато.", "Vyberte aplikaci a uvidíte, co by se odstranilo.", "Vælg en app for at se, hvad der ville blive fjernet.", "Επιλέξτε μια εφαρμογή για να δείτε τι θα αφαιρεθεί.", "Elige una aplicación para ver qué se eliminaría.", "Valitse sovellus, niin näet, mitä poistettaisiin.", "Válasszon egy alkalmazást, hogy lássa, mi kerülne eltávolításra.", "Pilih aplikasi untuk melihat apa yang akan dihapus.", "Pilih apl untuk melihat apa yang akan dibuang.", "Velg en app for å se hva som ville bli fjernet.", "Escolha uma aplicação para ver o que seria eliminado.", "Alege o aplicație pentru a vedea ce s-ar elimina.", "Välj en app för att se vad som skulle tas bort.", "เลือกแอปเพื่อดูสิ่งที่จะถูกลบ", "Виберіть програму, щоб побачити, що буде видалено.", "Chọn một ứng dụng để xem những gì sẽ bị gỡ."],
    "files.mode.large": ["Големи файлове", "Velké soubory", "Store filer", "Μεγάλα αρχεία", "Archivos grandes", "Suuret tiedostot", "Nagy fájlok", "File besar", "Fail besar", "Store filer", "Ficheiros grandes", "Fișiere mari", "Stora filer", "ไฟล์ขนาดใหญ่", "Великі файли", "Tệp lớn"],
    "files.mode.old": ["Стари файлове", "Staré soubory", "Gamle filer", "Παλιά αρχεία", "Archivos antiguos", "Vanhat tiedostot", "Régi fájlok", "File lama", "Fail lama", "Gamle filer", "Ficheiros antigos", "Fișiere vechi", "Gamla filer", "ไฟล์เก่า", "Старі файли", "Tệp cũ"],
    "files.mode.duplicates": ["Дубликати", "Duplikáty", "Dubletter", "Διπλότυπα", "Duplicados", "Kaksoiskappaleet", "Duplikátumok", "Duplikat", "Pendua", "Duplikater", "Duplicados", "Duplicate", "Dubbletter", "ไฟล์ซ้ำ", "Дублікати", "Tệp trùng"],
    "files.duplicateGroups": ["Групи дубликати: %d, може да се освободят %@", "Skupiny duplikátů: %d, uvolnitelné %@", "%d dubletgrupper, %@ kan frigives", "%d ομάδες διπλοτύπων, %@ ανακτήσιμα", "%d grupos de duplicados, %@ recuperables", "%d kaksoiskappaleryhmää, %@ vapautettavissa", "%d duplikátumcsoport, %@ visszanyerhető", "%d kelompok duplikat, %@ dapat diklaim", "%d kumpulan pendua, %@ boleh dituntut semula", "%d duplikatgrupper, %@ kan frigjøres", "%d grupos de duplicados, %@ recuperáveis", "%d grupuri de duplicate, %@ recuperabili", "%d dubblettgrupper, %@ kan frigöras", "%d กลุ่มไฟล์ซ้ำ กู้คืนได้ %@", "Груп дублікатів: %d, можна звільнити %@", "%d nhóm tệp trùng, có thể thu hồi %@"],
    "files.duplicateGroupsShown": ["Показани %d от %d групи", "Zobrazeno %d z %d skupin", "Viser %d af %d grupper", "Εμφάνιση %d από %d ομάδες", "Mostrando %d de %d grupos", "Näytetään %d / %d ryhmää", "%d / %d csoport megjelenítve", "Menampilkan %d dari %d kelompok", "Memaparkan %d daripada %d kumpulan", "Viser %d av %d grupper", "A mostrar %d de %d grupos", "Se afișează %d din %d grupuri", "Visar %d av %d grupper", "แสดง %d จาก %d กลุ่ม", "Показано %d із %d груп", "Đang hiển thị %d trong %d nhóm"],
    "files.groupMembers": ["%d копия", "Kopie: %d", "%d kopier", "%d αντίγραφα", "%d copias", "%d kopiota", "%d példány", "%d salinan", "%d salinan", "%d kopier", "%d cópias", "Copii: %d", "%d kopior", "%d ชุด", "Копій: %d", "%d bản sao"],
    "files.keepThis": ["Запазете това", "Ponechat tuto", "Behold denne", "Διατήρηση αυτού", "Conservar esta", "Säilytä tämä", "Ezt tartsa meg", "Simpan yang ini", "Simpan yang ini", "Behold denne", "Manter esta", "Păstrează aceasta", "Behåll den här", "เก็บชุดนี้", "Залишити цю", "Giữ bản này"],
    "files.noDuplicates": ["Не са намерени дублирани файлове", "Nebyly nalezeny žádné duplicitní soubory", "Ingen dublerede filer fundet", "Δεν βρέθηκαν διπλότυπα αρχεία", "No se encontraron archivos duplicados", "Kaksoiskappaleita ei löytynyt", "Nem találhatók duplikált fájlok", "Tidak ada file duplikat yang ditemukan", "Tiada fail pendua ditemui", "Ingen duplikatfiler funnet", "Não foram encontrados ficheiros duplicados", "Nu s-au găsit fișiere duplicate", "Inga dubblettfiler hittades", "ไม่พบไฟล์ซ้ำ", "Дублікатів файлів не знайдено", "Không tìm thấy tệp trùng"],
    "files.revealInFinder": ["Покажете в Finder", "Zobrazit ve Finderu", "Vis i Finder", "Εμφάνιση στο Finder", "Mostrar en el Finder", "Näytä Finderissä", "Megjelenítés a Finderben", "Tampilkan di Finder", "Tunjukkan dalam Finder", "Vis i Finder", "Mostrar no Finder", "Arată în Finder", "Visa i Finder", "แสดงใน Finder", "Показати у Finder", "Hiện trong Finder"],
    "files.requiresAuthorization": ["Sift сканира „Изтегляния“, „Работен плот“ и папките, които изберете. Добавете папка, за да я включите.", "Sift skenuje Stažené soubory, Plochu a složky, které vyberete. Přidáním složky ji zahrnete.", "Sift scanner Downloads, Skrivebord og de mapper, du vælger. Tilføj en mappe for at medtage den.", "Το Sift σαρώνει τους φακέλους Λήψεις, Επιφάνεια εργασίας και φακέλους που επιλέγετε. Προσθέστε έναν φάκελο για να τον συμπεριλάβετε.", "Sift analiza Descargas, Escritorio y las carpetas que elijas. Agrega una carpeta para incluirla.", "Sift skannaa Lataukset-, Työpöytä- ja valitsemasi kansiot. Lisää kansio, niin se otetaan mukaan.", "A Sift a Letöltéseket, az Asztalt és az Ön által választott mappákat vizsgálja. Adjon hozzá egy mappát a felvételéhez.", "Sift memindai Downloads, Desktop, dan folder yang Anda pilih. Tambahkan folder untuk menyertakannya.", "Sift mengimbas Downloads, Desktop dan folder yang anda pilih. Tambah folder untuk menyertakannya.", "Sift skanner Nedlastinger, Skrivebord og mapper du velger. Legg til en mappe for å ta den med.", "O Sift verifica as pastas Downloads e Secretária, bem como as pastas que escolher. Adicione uma pasta para a incluir.", "Sift scanează Descărcări, Desktop și folderele pe care le alegi. Adaugă un folder pentru a-l include.", "Sift skannar Hämtade filer, Skrivbord och mappar du väljer. Lägg till en mapp för att inkludera den.", "Sift สแกนโฟลเดอร์ Downloads, Desktop และโฟลเดอร์ที่คุณเลือก เพิ่มโฟลเดอร์เพื่อรวมไว้", "Sift сканує «Завантаження», «Робочий стіл» і вибрані вами папки. Додайте папку, щоб включити її.", "Sift quét Downloads, Desktop và các thư mục bạn chọn. Hãy thêm thư mục để đưa vào phạm vi."],
    "files.addFolder": ["Добавете папка", "Přidat složku", "Tilføj mappe", "Προσθήκη φακέλου", "Agregar carpeta", "Lisää kansio", "Mappa hozzáadása", "Tambahkan folder", "Tambah folder", "Legg til mappe", "Adicionar pasta", "Adaugă folder", "Lägg till mapp", "เพิ่มโฟลเดอร์", "Додати папку", "Thêm thư mục"],
    "diagnostics.category.spotlightIndex": ["Индекс на Spotlight", "Index Spotlight", "Spotlight-indeks", "Ευρετήριο Spotlight", "Índice de Spotlight", "Spotlight-hakemisto", "Spotlight index", "Indeks Spotlight", "Indeks Spotlight", "Spotlight-indeks", "Índice do Spotlight", "Index Spotlight", "Spotlight-index", "ดัชนี Spotlight", "Індекс Spotlight", "Chỉ mục Spotlight"],
    "diagnostics.category.coreSpotlightIndex": ["Метаданни за търсене", "Metadata vyhledávání", "Søgemetadata", "Μεταδεδομένα αναζήτησης", "Metadatos de búsqueda", "Hakumetatiedot", "Keresési metaadatok", "Metadata pencarian", "Metadata carian", "Søkemetadata", "Metadados de pesquisa", "Metadate de căutare", "Sökmetadata", "ข้อมูลเมตาการค้นหา", "Метадані пошуку", "Siêu dữ liệu tìm kiếm"],
    "diagnostics.category.developerIndex": ["Индекс за разработка", "Vývojářský index", "Udviklingsindeks", "Ευρετήριο ανάπτυξης", "Índice de desarrollo", "Kehityshakemisto", "Fejlesztői index", "Indeks pengembangan", "Indeks pembangunan", "Utviklingsindeks", "Índice de desenvolvimento", "Index de dezvoltare", "Utvecklingsindex", "ดัชนีการพัฒนา", "Індекс розробки", "Chỉ mục phát triển"],
    "diagnostics.category.applicationDatabase": ["База данни на приложение", "Databáze aplikací", "App-database", "Βάση δεδομένων εφαρμογής", "Base de datos de la aplicación", "Sovellustietokanta", "Alkalmazásadatbázis", "Basis data aplikasi", "Pangkalan data apl", "Appdatabase", "Base de dados da aplicação", "Bază de date a aplicațiilor", "Appdatabas", "ฐานข้อมูลของแอป", "База даних програми", "Cơ sở dữ liệu ứng dụng"],
    "diagnostics.category.filesystemSnapshot": ["Снимка на APFS", "Snímek APFS", "APFS-snapshot", "Στιγμιότυπο APFS", "Instantánea de APFS", "APFS-tilannekuva", "APFS pillanatkép", "Snapshot APFS", "Petikan APFS", "APFS-øyeblikksbilde", "Instantâneo do APFS", "Instantaneu APFS", "APFS-ögonblicksbild", "สแนปชอต APFS", "Знімок APFS", "Ảnh chụp APFS"],
    "diagnostics.category.systemCache": ["Системен кеш", "Systémová mezipaměť", "Systemcache", "Cache συστήματος", "Caché del sistema", "Järjestelmän välimuisti", "Rendszer-gyorsítótár", "Cache sistem", "Cache sistem", "Systemcache", "Cache do sistema", "Cache de sistem", "Systemcache", "แคชของระบบ", "Системний кеш", "Bộ nhớ đệm hệ thống"],
    "diagnostics.category.systemData": ["Системни данни", "Systémová data", "Systemdata", "Δεδομένα συστήματος", "Datos del sistema", "Järjestelmätiedot", "Rendszeradatok", "Data sistem", "Data sistem", "Systemdata", "Dados do sistema", "Date de sistem", "Systemdata", "ข้อมูลระบบ", "Системні дані", "Dữ liệu hệ thống"],
    "diagnostics.category.userData": ["Вашите данни", "Vaše data", "Dine data", "Τα δεδομένα σας", "Tus datos", "Omat tietosi", "Az Ön adatai", "Data Anda", "Data anda", "Dine data", "Os seus dados", "Datele tale", "Dina data", "ข้อมูลของคุณ", "Ваші дані", "Dữ liệu của bạn"],
    "diagnostics.category.unknown": ["Без категория", "Nezařazeno", "Ikke klassificeret", "Μη ταξινομημένο", "Sin clasificar", "Luokittelematon", "Besorolatlan", "Tidak terklasifikasi", "Tidak dikelaskan", "Ikke klassifisert", "Sem classificação", "Neclasificat", "Oklassificerat", "ไม่จัดประเภท", "Без категорії", "Chưa phân loại"],
    "diagnostics.status.cleanable": ["Може да се почисти", "Lze vyčistit", "Kan ryddes", "Μπορεί να καθαριστεί", "Se puede limpiar", "Siivottavissa", "Tisztítható", "Dapat dibersihkan", "Boleh dibersihkan", "Kan ryddes", "Pode ser limpo", "Poate fi curățat", "Kan rensas", "ล้างได้", "Можна очистити", "Có thể dọn"],
    "diagnostics.status.rebuildable": ["Може да се създаде отново", "Lze vytvořit znovu", "Kan genopbygges", "Μπορεί να δημιουργηθεί ξανά", "Se puede reconstruir", "Voidaan luoda uudelleen", "Újraépíthető", "Dapat dibangun ulang", "Boleh dibina semula", "Kan bygges på nytt", "Pode ser reconstruído", "Poate fi reconstruit", "Kan byggas upp igen", "สร้างใหม่ได้", "Можна відбудувати", "Có thể tạo lại"],
    "diagnostics.status.protected": ["Защитено", "Chráněno", "Beskyttet", "Προστατευμένο", "Protegido", "Suojattu", "Védett", "Dilindungi", "Dilindungi", "Beskyttet", "Protegido", "Protejat", "Skyddad", "ป้องกันอยู่", "Захищено", "Được bảo vệ"],
    "diagnostics.status.unknown": ["Не е оценено", "Neposouzeno", "Ikke vurderet", "Χωρίς αξιολόγηση", "Sin evaluar", "Ei arvioitu", "Nincs megítélve", "Tidak dinilai", "Tidak dinilai", "Ikke vurdert", "Não avaliado", "Nejudecat", "Inte bedömd", "ยังไม่ประเมิน", "Не оцінено", "Chưa đánh giá"],
    "diagnostics.remediation.trash": ["Премества се в Кошчето след потвърждение", "Po potvrzení se přesune do Koše", "Flyttes til Papirkurven, når du bekræfter", "Μετακινείται στον Κάδο μετά την επιβεβαίωσή σας", "Se mueve a la Papelera después de confirmar", "Siirretään Roskakoriin, kun vahvistat", "Megerősítés után a Kukába kerül", "Dipindahkan ke Tempat Sampah setelah Anda mengonfirmasi", "Dialihkan ke Tong Sampah selepas anda mengesahkan", "Flyttes til Papirkurven når du bekrefter", "É movido para o Lixo depois da confirmação", "Se mută în Coș după ce confirmi", "Flyttas till Papperskorgen när du bekräftar", "ย้ายไปที่ถังขยะหลังจากคุณยืนยัน", "Переміщується в Кошик після підтвердження", "Được chuyển vào Thùng rác sau khi bạn xác nhận"],
    "diagnostics.remediation.spotlight": ["Създайте отново с Spotlight: mdutil -E", "Vytvořit znovu pomocí Spotlightu: mdutil -E", "Genopbyg med Spotlight: mdutil -E", "Δημιουργήστε το ξανά με το Spotlight: mdutil -E", "Reconstruirlo con Spotlight: mdutil -E", "Luo uudelleen Spotlightilla: mdutil -E", "Építse újra a Spotlighttal: mdutil -E", "Bangun ulang dengan Spotlight: mdutil -E", "Bina semula dengan Spotlight: mdutil -E", "Bygg det på nytt med Spotlight: mdutil -E", "Reconstruir com o Spotlight: mdutil -E", "Reconstruiește-l cu Spotlight: mdutil -E", "Bygg upp det igen med Spotlight: mdutil -E", "สร้างใหม่ด้วย Spotlight: mdutil -E", "Відбудуйте через Spotlight: mdutil -E", "Tạo lại bằng Spotlight: mdutil -E"],
    "diagnostics.remediation.owningApplication": ["Създайте отново от програмата, която го е създала", "Vytvořit znovu v nástroji, který jej vytvořil", "Genopbyg det fra værktøjet, der oprettede det", "Δημιουργήστε το ξανά από το εργαλείο που το δημιούργησε", "Reconstruirlo desde la herramienta que lo creó", "Luo uudelleen työkalulla, joka sen teki", "Építse újra az azt létrehozó eszközzel", "Bangun ulang dari alat yang membuatnya", "Bina semula daripada alat yang menghasilkannya", "Bygg det på nytt fra verktøyet som laget det", "Reconstruir com a ferramenta que o criou", "Reconstruiește-l din instrumentul care l-a creat", "Bygg upp det igen från verktyget som skapade det", "สร้างใหม่จากเครื่องมือที่สร้างมันขึ้นมา", "Відбудуйте в інструменті, що його створив", "Tạo lại từ công cụ đã tạo ra nó"],
    "diagnostics.remediation.inspectOnly": ["Показано само за информация", "Zobrazeno pouze pro informaci", "Vises kun som information", "Εμφανίζεται μόνο ενημερωτικά", "Solo se muestra a modo informativo", "Näytetään vain tiedoksi", "Csak tájékoztatásul jelenik meg", "Ditampilkan hanya sebagai informasi", "Dipaparkan untuk maklumat sahaja", "Vises bare som informasjon", "Apresentado apenas a título informativo", "Afișat doar pentru informare", "Visas endast som information", "แสดงไว้เพื่อเป็นข้อมูลเท่านั้น", "Показано лише для інформації", "Chỉ hiển thị để tham khảo"],
    "diagnostics.coverage.complete": ["Този резултат обхваща всичко заявено.", "Tento výsledek pokrývá vše, co bylo požadováno.", "Dette resultat dækker alt, der blev anmodet om.", "Αυτό το αποτέλεσμα καλύπτει ό,τι ζητήθηκε.", "Este resultado abarca todo lo solicitado.", "Tämä tulos kattaa kaiken, mitä pyydettiin.", "Ez az eredmény mindent lefed, amit kértek.", "Hasil ini mencakup semua yang diminta.", "Hasil ini merangkumi semua yang diminta.", "Dette resultatet dekker alt som ble bedt om.", "Este resultado abrange tudo o que foi pedido.", "Acest rezultat acoperă tot ce a fost solicitat.", "Det här resultatet omfattar allt som efterfrågades.", "ผลลัพธ์นี้ครอบคลุมทุกอย่างที่ขอ", "Цей результат охоплює все, що було запитано.", "Kết quả này bao gồm mọi thứ được yêu cầu."],
    "diagnostics.coverage.partial": ["Част от обхвата не можа да бъде измерена, затова общите стойности са долна граница.", "Část rozsahu nebylo možné změřit, takže součty jsou spodní hranicí.", "En del af området kunne ikke måles, så totalerne er et minimum.", "Ένα μέρος του εύρους δεν ήταν δυνατό να μετρηθεί, οπότε τα σύνολα είναι κατώτερο όριο.", "No se pudo medir parte del alcance, así que los totales son un límite inferior.", "Osaa alueesta ei voitu mitata, joten kokonaismäärät ovat alaraja.", "A hatókör egy részét nem sikerült megmérni, ezért az összegek alsó határt jelentenek.", "Sebagian cakupan tidak dapat diukur, jadi totalnya merupakan batas bawah.", "Sebahagian skop tidak dapat diukur, jadi jumlahnya ialah had bawah.", "En del av området kunne ikke måles, så totalene er et minimum.", "Parte do âmbito não pôde ser medida, pelo que os totais são um limite inferior.", "O parte a domeniului nu a putut fi măsurată, așa că totalurile sunt o limită inferioară.", "En del av omfånget kunde inte mätas, så totalerna är en undre gräns.", "ไม่สามารถวัดขอบเขตบางส่วนได้ ยอดรวมจึงเป็นค่าต่ำสุด", "Частину обсягу не вдалося виміряти, тож підсумки є нижньою межею.", "Không thể đo một phần phạm vi, nên tổng số là mức tối thiểu."],
    "diagnostics.coverage.permissionDenied": ["Някои места изискват Пълен достъп до диска, преди да могат да бъдат измерени.", "Některá místa vyžadují před změřením Úplný přístup k disku.", "Nogle placeringer kræver fuld diskadgang, før de kan måles.", "Ορισμένες τοποθεσίες απαιτούν Πλήρη πρόσβαση στον δίσκο για να μετρηθούν.", "Algunas ubicaciones necesitan Acceso total al disco para poder medirse.", "Jotkin sijainnit vaativat täyden levynkäyttöoikeuden ennen mittaamista.", "Néhány hely csak Teljes lemezhozzáféréssel mérhető meg.", "Beberapa lokasi memerlukan Akses Disk Penuh sebelum dapat diukur.", "Sesetengah lokasi memerlukan Akses Cakera Penuh sebelum boleh diukur.", "Noen steder krever full disktilgang før de kan måles.", "Alguns locais requerem Acesso Total ao Disco para poderem ser medidos.", "Unele locații necesită Acces complet la disc înainte de a putea fi măsurate.", "Vissa platser kräver fullskivåtkomst innan de kan mätas.", "บางตำแหน่งต้องใช้การเข้าถึงดิสก์ทั้งหมดก่อนจึงจะวัดได้", "Деякі місця потребують Повного доступу до диска, перш ніж їх можна буде виміряти.", "Một số vị trí cần Quyền truy cập Toàn bộ Đĩa trước khi có thể đo."],
    "diagnostics.coverage.volumeUnavailable": ["Един том вече не е достъпен и не беше измерен.", "Svazek už není dostupný, proto nebyl změřen.", "En disk er ikke længere tilgængelig og blev derfor ikke målt.", "Ένας τόμος δεν είναι πλέον διαθέσιμος και δεν μετρήθηκε.", "Un volumen ya no está disponible, por lo que no se midió.", "Levy ei ole enää käytettävissä, joten sitä ei mitattu.", "Egy kötet már nem érhető el, ezért nem mértük meg.", "Sebuah volume tidak lagi tersedia, jadi tidak diukur.", "Satu volum tidak lagi tersedia, jadi ia tidak diukur.", "En disk er ikke lenger tilgjengelig, og ble derfor ikke målt.", "Um volume já não está disponível, pelo que não foi medido.", "Un volum nu mai este disponibil, așa că nu a fost măsurat.", "En disk är inte längre tillgänglig och mättes därför inte.", "โวลุ่มไม่พร้อมใช้งานแล้ว จึงไม่ได้วัด", "Один том більше недоступний, тому його не вимірювано.", "Một ổ đĩa không còn khả dụng nên không được đo."],
    "diagnostics.explanation.volumeChild": ["Папка на най-горно ниво на тома.", "Složka na nejvyšší úrovni svazku.", "En mappe på øverste niveau af disken.", "Ένας κατάλογος στο ανώτατο επίπεδο του τόμου.", "Un directorio en el nivel superior del volumen.", "Kansio levyn ylimmällä tasolla.", "A kötet legfelső szintjén lévő mappa.", "Direktori di tingkat teratas volume.", "Direktori pada peringkat teratas volum.", "En mappe på øverste nivå av disken.", "Uma pasta no nível superior do volume.", "Un folder de la nivelul superior al volumului.", "En mapp på diskens översta nivå.", "ไดเรกทอรีที่อยู่ระดับบนสุดของโวลุ่ม", "Каталог верхнього рівня тому.", "Một thư mục ở cấp cao nhất của ổ đĩa."],
    "diagnostics.explanation.systemData": ["Част от macOS или неговите библиотеки. Заема място и не може да бъде премахната.", "Součást macOS nebo jeho knihoven. Zabírá místo a nelze ji odstranit.", "En del af macOS eller dets biblioteker. Den optager plads og kan ikke fjernes.", "Μέρος του macOS ή των βιβλιοθηκών του. Καταλαμβάνει χώρο και δεν μπορεί να αφαιρεθεί.", "Parte de macOS o de sus bibliotecas. Ocupa espacio y no se puede eliminar.", "Osa macOS:ää tai sen kirjastoja. Se vie tilaa, eikä sitä voi poistaa.", "A macOS vagy könyvtárai része. Helyet foglal, és nem távolítható el.", "Bagian dari macOS atau pustakanya. Menempati ruang dan tidak dapat dihapus.", "Sebahagian daripada macOS atau pustakanya. Ia menggunakan ruang dan tidak boleh dibuang.", "En del av macOS eller bibliotekene. Den tar plass og kan ikke fjernes.", "Parte do macOS ou das suas bibliotecas. Ocupa espaço e não pode ser eliminada.", "Parte din macOS sau din bibliotecile sale. Ocupă spațiu și nu poate fi eliminat.", "En del av macOS eller dess bibliotek. Den tar plats och kan inte tas bort.", "ส่วนหนึ่งของ macOS หรือไลบรารีของระบบ ใช้พื้นที่และไม่สามารถลบได้", "Частина macOS або її бібліотек. Займає місце й не може бути видалена.", "Một phần của macOS hoặc các thư viện của nó. Nó chiếm dung lượng và không thể xóa."],
    "diagnostics.explanation.spotlightIndexed": ["Индексът на Spotlight за този том; индексирането в момента е включено. macOS го създава отново с mdutil -E — преместването му в Кошчето само прави търсенето недостъпно, докато не бъде създаден отново.", "Index Spotlightu pro tento svazek; indexování je právě zapnuto. macOS jej vytvoří znovu pomocí mdutil -E — přesun do Koše jen znepřístupní vyhledávání, dokud nebude vytvořen znovu.", "Spotlights indeks for denne disk; indeksering er i øjeblikket slået til. macOS genopbygger det med mdutil -E – flytning til Papirkurven gør kun søgning utilgængelig, indtil det er genopbygget.", "Το ευρετήριο του Spotlight για αυτόν τον τόμο, η ευρετηρίαση είναι προς το παρόν ενεργή. Το macOS το δημιουργεί ξανά με mdutil -E — η μετακίνησή του στον Κάδο κάνει απλώς την αναζήτηση μη διαθέσιμη μέχρι να δημιουργηθεί ξανά.", "Índice de Spotlight de este volumen; la indexación está activada. macOS lo reconstruye con mdutil -E: moverlo a la Papelera solo deja la búsqueda no disponible hasta que se reconstruya.", "Spotlightin hakemisto tälle levylle; indeksointi on tällä hetkellä päällä. macOS luo sen uudelleen komennolla mdutil -E – Roskakoriin siirtäminen tekee vain hausta käyttökelvottoman, kunnes se luodaan uudelleen.", "A Spotlight indexe ehhez a kötethez; az indexelés jelenleg be van kapcsolva. A macOS újraépíti az mdutil -E paranccsal – a Kukába helyezés csak addig teszi elérhetetlenné a keresést, amíg újra nem épül.", "Indeks Spotlight untuk volume ini; pengindeksan sedang aktif. macOS membangun ulangnya dengan mdutil -E — memindahkannya ke Tempat Sampah hanya membuat pencarian tidak tersedia sampai dibangun ulang.", "Indeks Spotlight untuk volum ini; pengindeksan sedang aktif. macOS membinanya semula dengan mdutil -E — mengalihkannya ke Tong Sampah hanya menjadikan carian tidak tersedia sehingga ia dibina semula.", "Spotlights indeks for denne disken; indeksering er slått på nå. macOS bygger den på nytt med mdutil -E – flytting til Papirkurven gjør bare søk utilgjengelig til den er bygget på nytt.", "Índice do Spotlight deste volume; a indexação está ativa. O macOS reconstrói-o com mdutil -E — movê-lo para o Lixo apenas torna a pesquisa indisponível até ser reconstruído.", "Indexul Spotlight pentru acest volum; indexarea este activă acum. macOS îl reconstruiește cu mdutil -E — mutarea lui în Coș doar face căutarea indisponibilă până la reconstruire.", "Spotlights index för den här disken; indexering är för närvarande på. macOS bygger upp det igen med mdutil -E – att flytta det till Papperskorgen gör bara sökning otillgänglig tills det har byggts upp igen.", "ดัชนีของ Spotlight สำหรับโวลุ่มนี้ ขณะนี้การทำดัชนีเปิดอยู่ macOS จะสร้างใหม่ด้วย mdutil -E การย้ายไปที่ถังขยะเพียงทำให้การค้นหาใช้ไม่ได้จนกว่าจะสร้างใหม่", "Індекс Spotlight для цього тому; індексування наразі ввімкнено. macOS відбудовує його через mdutil -E — переміщення в Кошик лише зробить пошук недоступним, доки його не відбудовано.", "Chỉ mục của Spotlight cho ổ đĩa này; tính năng lập chỉ mục hiện đang bật. macOS tạo lại bằng mdutil -E — chuyển nó vào Thùng rác chỉ khiến tìm kiếm không dùng được cho đến khi được tạo lại."],
    "diagnostics.explanation.spotlightNotIndexed": ["Индексът на Spotlight за този том; индексирането в момента е изключено. macOS управлява тази папка.", "Index Spotlightu pro tento svazek; indexování se nyní hlásí jako vypnuté. Tuto složku spravuje macOS.", "Spotlights indeks for denne disk; indeksering rapporteres i øjeblikket som slået fra. macOS administrerer denne mappe.", "Το ευρετήριο του Spotlight για αυτόν τον τόμο, η ευρετηρίαση αναφέρεται προς το παρόν ως ανενεργή. Το macOS διαχειρίζεται αυτόν τον κατάλογο.", "Índice de Spotlight de este volumen; la indexación figura como desactivada. macOS gestiona este directorio.", "Spotlightin hakemisto tälle levylle; indeksointi ilmoitetaan tällä hetkellä pois päältä. macOS hallitsee tätä kansiota.", "A Spotlight indexe ehhez a kötethez; az indexelés jelenleg kikapcsoltként jelentkezik. Ezt a mappát a macOS kezeli.", "Indeks Spotlight untuk volume ini; pengindeksan saat ini dilaporkan nonaktif. macOS mengelola direktori ini.", "Indeks Spotlight untuk volum ini; pengindeksan kini dilaporkan tidak aktif. macOS mengurus direktori ini.", "Spotlights indeks for denne disken; indeksering rapporteres nå som av. macOS administrerer denne mappen.", "Índice do Spotlight deste volume; a indexação está indicada como desativada. Esta pasta é gerida pelo macOS.", "Indexul Spotlight pentru acest volum; indexarea este raportată ca dezactivată. macOS gestionează acest folder.", "Spotlights index för den här disken; indexering rapporteras för närvarande som av. macOS hanterar den här mappen.", "ดัชนีของ Spotlight สำหรับโวลุ่มนี้ ขณะนี้รายงานว่าการทำดัชนีปิดอยู่ macOS เป็นผู้จัดการไดเรกทอรีนี้", "Індекс Spotlight для цього тому; індексування наразі вимкнено. Цим каталогом керує macOS.", "Chỉ mục của Spotlight cho ổ đĩa này; tính năng lập chỉ mục hiện báo là tắt. macOS quản lý thư mục này."],
    "diagnostics.explanation.spotlightStateUnknown": ["Индексът на Spotlight за този том. Какво прави Spotlight в момента не можа да бъде прочетено.", "Index Spotlightu pro tento svazek. Co Spotlight právě dělá, nešlo zjistit.", "Spotlights indeks for denne disk. Det kunne ikke læses, hvad Spotlight i øjeblikket laver.", "Το ευρετήριο του Spotlight για αυτόν τον τόμο. Δεν ήταν δυνατό να διαβαστεί τι κάνει το Spotlight αυτή τη στιγμή.", "Índice de Spotlight de este volumen. No se pudo leer qué está haciendo Spotlight en este momento.", "Spotlightin hakemisto tälle levylle. Ei voitu lukea, mitä Spotlight tekee juuri nyt.", "A Spotlight indexe ehhez a kötethez. Nem sikerült beolvasni, mit tesz éppen a Spotlight.", "Indeks Spotlight untuk volume ini. Apa yang sedang dilakukan Spotlight tidak dapat dibaca.", "Indeks Spotlight untuk volum ini. Apa yang sedang dilakukan Spotlight tidak dapat dibaca.", "Spotlights indeks for denne disken. Det kunne ikke leses hva Spotlight gjør nå.", "Índice do Spotlight deste volume. Não foi possível ler o que o Spotlight está a fazer neste momento.", "Indexul Spotlight pentru acest volum. Nu s-a putut afla ce face Spotlight acum.", "Spotlights index för den här disken. Det gick inte att läsa vad Spotlight gör just nu.", "ดัชนีของ Spotlight สำหรับโวลุ่มนี้ ไม่สามารถอ่านสถานะปัจจุบันของ Spotlight ได้", "Індекс Spotlight для цього тому. Що Spotlight робить зараз, прочитати не вдалося.", "Chỉ mục của Spotlight cho ổ đĩa này. Không thể đọc được trạng thái hiện tại của Spotlight."],
    "diagnostics.explanation.spotlightUnreadable": ["Индексът на Spotlight за този том. Размерът му не можа да бъде прочетен: нужен е Пълен достъп до диска.", "Index Spotlightu pro tento svazek. Jeho velikost nešlo zjistit: je potřeba Úplný přístup k disku.", "Spotlights indeks for denne disk. Størrelsen kunne ikke læses: fuld diskadgang er påkrævet.", "Το ευρετήριο του Spotlight για αυτόν τον τόμο. Δεν ήταν δυνατό να διαβαστεί το μέγεθός του: απαιτείται Πλήρης πρόσβαση στον δίσκο.", "Índice de Spotlight de este volumen. No se pudo leer su tamaño: se necesita Acceso total al disco.", "Spotlightin hakemisto tälle levylle. Kokoa ei voitu lukea: täysi levynkäyttöoikeus vaaditaan.", "A Spotlight indexe ehhez a kötethez. A méretét nem sikerült beolvasni: Teljes lemezhozzáférés szükséges.", "Indeks Spotlight untuk volume ini. Ukurannya tidak dapat dibaca: Akses Disk Penuh diperlukan.", "Indeks Spotlight untuk volum ini. Saiznya tidak dapat dibaca: Akses Cakera Penuh diperlukan.", "Spotlights indeks for denne disken. Størrelsen kunne ikke leses: full disktilgang kreves.", "Índice do Spotlight deste volume. Não foi possível ler o tamanho: é necessário Acesso Total ao Disco.", "Indexul Spotlight pentru acest volum. Dimensiunea lui nu a putut fi citită: este necesar Accesul complet la disc.", "Spotlights index för den här disken. Storleken kunde inte läsas: fullskivåtkomst krävs.", "ดัชนีของ Spotlight สำหรับโวลุ่มนี้ ไม่สามารถอ่านขนาดได้: ต้องใช้การเข้าถึงดิสก์ทั้งหมด", "Індекс Spotlight для цього тому. Його розмір прочитати не вдалося: потрібен Повний доступ до диска.", "Chỉ mục của Spotlight cho ổ đĩa này. Không thể đọc kích thước: cần Quyền truy cập Toàn bộ Đĩa."],
    "diagnostics.explanation.coreSpotlight": ["Метаданни за търсене, които системата пази за вашето съдържание, например поща и съобщения. Създаването им отново може да отнеме време и търсенето е непълно, докато не завърши.", "Metadata vyhledávání, která systém uchovává k vašemu obsahu, například k mailům a zprávám. Nové vytvoření může chvíli trvat a vyhledávání je do dokončení neúplné.", "Søgemetadata, som systemet gemmer for dit eget indhold, f.eks. mail og beskeder. Genopbygning kan tage tid, og søgning er ufuldstændig, indtil den er færdig.", "Μεταδεδομένα αναζήτησης που κρατά το σύστημα για το δικό σας περιεχόμενο, όπως αλληλογραφία και μηνύματα. Η αναδημιουργία τους μπορεί να διαρκέσει, και η αναζήτηση είναι ελλιπής μέχρι να ολοκληρωθεί.", "Metadatos de búsqueda que el sistema guarda para tu propio contenido, como correo y mensajes. Reconstruirlos puede tardar y la búsqueda queda incompleta hasta que termina.", "Hakumetatiedot, joita järjestelmä säilyttää omalle sisällöllesi, kuten sähköpostille ja viesteille. Uudelleenluonti voi kestää, ja haku on puutteellinen, kunnes se valmistuu.", "A rendszer az Ön tartalmához, például levelekhez és üzenetekhez fenntartott keresési metaadatai. Az újraépítés eltarthat egy ideig, és a keresés addig hiányos.", "Metadata pencarian yang disimpan sistem untuk konten Anda sendiri, seperti email dan pesan. Membangunnya ulang bisa memakan waktu, dan pencarian tidak lengkap sampai selesai.", "Metadata carian yang disimpan sistem untuk kandungan anda sendiri, seperti mel dan mesej. Membinanya semula mungkin mengambil masa, dan carian tidak lengkap sehingga ia selesai.", "Søkemetadata som systemet lagrer for ditt eget innhold, for eksempel e-post og meldinger. Å bygge det på nytt kan ta tid, og søk er ufullstendig til det er ferdig.", "Metadados de pesquisa que o sistema guarda para o seu conteúdo, como correio e mensagens. Reconstruí-los pode demorar, e a pesquisa fica incompleta até terminar.", "Metadate de căutare pe care sistemul le păstrează pentru conținutul tău, cum ar fi e-mailurile și mesajele. Reconstruirea poate dura, iar căutarea este incompletă până se termină.", "Sökmetadata som systemet sparar för ditt eget innehåll, till exempel e-post och meddelanden. Att bygga upp det igen kan ta tid, och sökningen är ofullständig tills det är klart.", "ข้อมูลเมตาการค้นหาที่ระบบเก็บไว้สำหรับเนื้อหาของคุณ เช่น อีเมลและข้อความ การสร้างใหม่ใช้เวลาสักครู่ และการค้นหาจะไม่สมบูรณ์จนกว่าจะเสร็จ", "Метадані пошуку, які система зберігає для вашого вмісту, наприклад пошти й повідомлень. Відбудова може тривати, і пошук неповний, доки вона не завершиться.", "Siêu dữ liệu tìm kiếm mà hệ thống lưu cho nội dung của bạn, như thư và tin nhắn. Việc tạo lại có thể mất một lúc và tìm kiếm sẽ chưa đầy đủ cho đến khi hoàn tất."],
    "diagnostics.explanation.coreSpotlightUnreadable": ["Метаданни за търсене, които системата пази за вашето съдържание. Размерът им не можа да бъде прочетен: нужен е Пълен достъп до диска.", "Metadata vyhledávání, která systém uchovává k vašemu obsahu. Jejich velikost nešlo zjistit: je potřeba Úplný přístup k disku.", "Søgemetadata, som systemet gemmer for dit eget indhold. Størrelsen kunne ikke læses: fuld diskadgang er påkrævet.", "Μεταδεδομένα αναζήτησης που κρατά το σύστημα για το δικό σας περιεχόμενο. Δεν ήταν δυνατό να διαβαστεί το μέγεθός τους: απαιτείται Πλήρης πρόσβαση στον δίσκο.", "Metadatos de búsqueda que el sistema guarda para tu propio contenido. No se pudo leer su tamaño: se necesita Acceso total al disco.", "Hakumetatiedot, joita järjestelmä säilyttää omalle sisällöllesi. Kokoa ei voitu lukea: täysi levynkäyttöoikeus vaaditaan.", "A rendszer az Ön tartalmához fenntartott keresési metaadatai. A méretüket nem sikerült beolvasni: Teljes lemezhozzáférés szükséges.", "Metadata pencarian yang disimpan sistem untuk konten Anda sendiri. Ukurannya tidak dapat dibaca: Akses Disk Penuh diperlukan.", "Metadata carian yang disimpan sistem untuk kandungan anda sendiri. Saiznya tidak dapat dibaca: Akses Cakera Penuh diperlukan.", "Søkemetadata som systemet lagrer for ditt eget innhold. Størrelsen kunne ikke leses: full disktilgang kreves.", "Metadados de pesquisa que o sistema guarda para o seu conteúdo. Não foi possível ler o tamanho: é necessário Acesso Total ao Disco.", "Metadate de căutare pe care sistemul le păstrează pentru conținutul tău. Dimensiunea lor nu a putut fi citită: este necesar Accesul complet la disc.", "Sökmetadata som systemet sparar för ditt eget innehåll. Storleken kunde inte läsas: fullskivåtkomst krävs.", "ข้อมูลเมตาการค้นหาที่ระบบเก็บไว้สำหรับเนื้อหาของคุณ ไม่สามารถอ่านขนาดได้: ต้องใช้การเข้าถึงดิสก์ทั้งหมด", "Метадані пошуку, які система зберігає для вашого вмісту. Їхній розмір прочитати не вдалося: потрібен Повний доступ до диска.", "Siêu dữ liệu tìm kiếm mà hệ thống lưu cho nội dung của bạn. Không thể đọc kích thước: cần Quyền truy cập Toàn bộ Đĩa."],
    "diagnostics.explanation.developerIndex": ["Индекс, който инструмент за разработка е създал за този проект. Инструментът ще го създаде отново при нужда; дотогава автодовършването и търсенето на символи са по-бавни.", "Index, který pro tento projekt vytvořil vývojářský nástroj. Nástroj jej vytvoří znovu na vyžádání; do té doby je našeptávání kódu a hledání symbolů pomalejší.", "Et indeks, som et udviklingsværktøj har oprettet til dette projekt. Værktøjet genopbygger det efter behov; indtil da er kodefuldførelse og symbolsøgning langsommere.", "Ένα ευρετήριο που δημιούργησε εργαλείο ανάπτυξης για αυτό το έργο. Το εργαλείο το δημιουργεί ξανά κατόπιν αιτήματος, μέχρι τότε, η αυτόματη συμπλήρωση κώδικα και η αναζήτηση συμβόλων είναι πιο αργές.", "Índice que creó una herramienta de desarrollo para este proyecto. La herramienta lo reconstruye cuando hace falta; hasta entonces, el autocompletado y la búsqueda de símbolos son más lentos.", "Hakemisto, jonka kehitystyökalu on luonut tälle projektille. Työkalu luo sen uudelleen tarvittaessa; siihen asti koodin täydennys ja symbolihaku ovat hitaampia.", "Egy fejlesztőeszköz által ehhez a projekthez épített index. Az eszköz igény szerint újraépíti; addig a kódkiegészítés és a szimbólumkeresés lassabb.", "Indeks yang dibangun alat pengembangan untuk proyek ini. Alat tersebut membangunnya ulang saat diperlukan; sampai saat itu, pelengkapan kode dan pencarian simbol lebih lambat.", "Indeks yang dibina oleh alat pembangunan untuk projek ini. Alat itu membinanya semula apabila diperlukan; sehingga itu, pelengkapan kod dan carian simbol lebih perlahan.", "En indeks et utviklingsverktøy har laget for dette prosjektet. Verktøyet bygger den på nytt ved behov; til da er kodefullføring og symbolsøk tregere.", "Um índice criado por uma ferramenta de desenvolvimento para este projeto. A ferramenta reconstrói-o quando necessário; até lá, o preenchimento automático e a pesquisa de símbolos ficam mais lentos.", "Un index creat de un instrument de dezvoltare pentru acest proiect. Instrumentul îl reconstruiește la cerere; până atunci, completarea codului și căutarea simbolurilor sunt mai lente.", "Ett index som ett utvecklingsverktyg har skapat för det här projektet. Verktyget bygger upp det igen vid behov; tills dess är kodkomplettering och symbolsökning långsammare.", "ดัชนีที่เครื่องมือพัฒนาสร้างขึ้นสำหรับโปรเจกต์นี้ เครื่องมือจะสร้างใหม่เมื่อต้องการ จนกว่าจะถึงตอนนั้น การเติมโค้ดและการค้นหาสัญลักษณ์จะช้าลง", "Індекс, який інструмент розробки створив для цього проєкту. Інструмент відбудує його за потреби; доти автодоповнення й пошук символів повільніші.", "Chỉ mục do công cụ phát triển tạo cho dự án này. Công cụ sẽ tạo lại khi cần; cho đến lúc đó, gợi ý mã và tìm ký hiệu sẽ chậm hơn."],
    "diagnostics.explanation.developerData": ["Данни от компилация и кешове, които инструмент за разработка пази тук. Sift не може да прецени какво проектът може да създаде отново, затова нищо тук не се предлага за премахване.", "Data sestavení a mezipaměti, které zde vývojářský nástroj uchovává. Sift neposuzuje, co projekt umí vytvořit znovu, proto zde nic nenabízí k odstranění.", "Byggedata og caches, som et udviklingsværktøj gemmer her. Sift vurderer ikke, hvad et projekt kan genopbygge, så intet her tilbydes til fjernelse.", "Δεδομένα μεταγλώττισης και cache που κρατά εδώ ένα εργαλείο ανάπτυξης. Το Sift δεν κρίνει τι μπορεί να δημιουργήσει ξανά ένα έργο, οπότε τίποτα εδώ δεν προσφέρεται για αφαίρεση.", "Datos de compilación y cachés que guarda aquí una herramienta de desarrollo. Sift no evalúa qué puede reconstruir un proyecto, así que no ofrece nada de aquí para eliminar.", "Koontitiedot ja välimuistit, joita kehitystyökalu säilyttää täällä. Sift ei arvioi, mitä projekti voi luoda uudelleen, joten mitään täällä ei tarjota poistettavaksi.", "Egy fejlesztőeszköz által itt tartott build-adatok és gyorsítótárak. A Sift nem ítéli meg, mit tud újraépíteni egy projekt, ezért innen semmi nem ajánlható eltávolításra.", "Data build dan cache yang disimpan alat pengembangan di sini. Sift tidak menilai apa yang dapat dibangun ulang proyek, jadi tidak ada yang ditawarkan untuk dihapus.", "Data binaan dan cache yang disimpan alat pembangunan di sini. Sift tidak menilai apa yang boleh dibina semula oleh projek, jadi tiada apa-apa di sini ditawarkan untuk dibuang.", "Byggedata og cacher et utviklingsverktøy lagrer her. Sift vurderer ikke hva et prosjekt kan bygge på nytt, så ingenting her tilbys for fjerning.", "Dados de compilação e caches que uma ferramenta de desenvolvimento guarda aqui. O Sift não avalia o que um projeto pode reconstruir, pelo que nada aqui é proposto para eliminação.", "Date de compilare și cache-uri pe care un instrument de dezvoltare le păstrează aici. Sift nu judecă ce poate reconstrui un proiect, așa că nimic de aici nu este oferit spre eliminare.", "Byggdata och cacher som ett utvecklingsverktyg sparar här. Sift bedömer inte vad ett projekt kan bygga upp igen, så inget här erbjuds för borttagning.", "ข้อมูลการบิลด์และแคชที่เครื่องมือพัฒนาเก็บไว้ที่นี่ Sift ไม่ตัดสินว่าโปรเจกต์สร้างอะไรใหม่ได้ จึงไม่มีสิ่งใดที่นี่ถูกเสนอให้ลบ", "Дані збирання й кеші, які інструмент розробки зберігає тут. Sift не може оцінити, що проєкт здатен відбудувати, тому нічого звідси не пропонується до видалення.", "Dữ liệu bản dựng và bộ nhớ đệm mà công cụ phát triển lưu ở đây. Sift không đánh giá dự án có thể tạo lại gì, nên không có gì ở đây được đề nghị xóa."],
    "diagnostics.explanation.snapshots": ["Локални снимки на APFS. Те пазят състоянието на тома, macOS ги разрежда сама и системата не съобщава размер за отделна снимка.", "Místní snímky APFS. Uchovávají stav svazku, macOS je sám postupně ruší a systém neuvádí velikost jednotlivých snímků.", "Lokale APFS-snapshots. De gemmer diskens tilstand, macOS tynder dem selv ud, og systemet rapporterer ingen størrelse per snapshot.", "Τοπικά στιγμιότυπα APFS. Διατηρούν την κατάσταση του τόμου, το macOS τα περιορίζει μόνο του και το σύστημα δεν αναφέρει μέγεθος ανά στιγμιότυπο.", "Instantáneas locales de APFS. Guardan el estado del volumen, macOS las reduce por su cuenta y el sistema no informa el tamaño de cada una.", "Paikalliset APFS-tilannekuvat. Ne säilyttävät levyn tilan, macOS ohentaa niitä itse, eikä järjestelmä ilmoita tilannekuvakohtaista kokoa.", "Helyi APFS-pillanatképek. A kötet állapotát őrzik, a macOS maga ritkítja őket, és a rendszer nem ad meg pillanatképenkénti méretet.", "Snapshot lokal APFS. Snapshot menyimpan status volume, macOS memangkasnya sendiri, dan sistem tidak melaporkan ukuran per snapshot.", "Petikan setempat APFS. Petikan menyimpan keadaan volum, macOS menyusutkannya sendiri, dan sistem tidak melaporkan saiz bagi setiap petikan.", "Lokale APFS-øyeblikksbilder. De holder diskens tilstand, macOS tynner dem ut selv, og systemet rapporterer ingen størrelse per øyeblikksbilde.", "Instantâneos locais do APFS. Guardam o estado do volume, o macOS reduz o seu número automaticamente e o sistema não indica o tamanho de cada um.", "Instantaneuri locale APFS. Ele păstrează starea volumului, macOS le subțiază singur, iar sistemul nu raportează dimensiunea fiecărui instantaneu.", "Lokala APFS-ögonblicksbilder. De håller diskens tillstånd, macOS tunnar ut dem självt, och systemet rapporterar ingen storlek per ögonblicksbild.", "สแนปชอตภายในเครื่องของ APFS เก็บสถานะของโวลุ่ม macOS จะลดจำนวนเอง และระบบไม่รายงานขนาดของแต่ละสแนปชอต", "Локальні знімки APFS. Вони зберігають стан тому, macOS сама їх проріджує, а розмір окремого знімка система не повідомляє.", "Ảnh chụp cục bộ APFS. Chúng lưu trạng thái của ổ đĩa, macOS tự giảm bớt và hệ thống không báo kích thước của từng ảnh chụp."],
    "diagnostics.coverage.note": ["Отворете Системни настройки, за да дадете Пълен достъп до диска, и стартирайте анализа отново.", "Otevřete Nastavení systému, udělte Úplný přístup k disku a analýzu spusťte znovu.", "Åbn Systemindstillinger for at give fuld diskadgang, og kør analysen igen.", "Ανοίξτε τις Ρυθμίσεις συστήματος για να παραχωρήσετε Πλήρη πρόσβαση στον δίσκο και εκτελέστε ξανά την ανάλυση.", "Concede Acceso total al disco en Ajustes del Sistema y vuelve a ejecutar el análisis.", "Avaa Järjestelmäasetukset, myönnä täysi levynkäyttöoikeus ja suorita analyysi uudelleen.", "Nyissa meg a Rendszerbeállításokat a Teljes lemezhozzáférés megadásához, majd futtassa újra az elemzést.", "Buka Pengaturan Sistem untuk memberikan Akses Disk Penuh, lalu jalankan analisis lagi.", "Buka Tetapan Sistem untuk memberikan Akses Cakera Penuh, kemudian jalankan analisis semula.", "Åpne Systeminnstillinger for å gi full disktilgang, og kjør analysen igjen.", "Conceda Acesso Total ao Disco nas Definições do Sistema e execute novamente a análise.", "Deschide Configurările sistemului pentru a acorda Acces complet la disc, apoi rulează din nou analiza.", "Öppna Systeminställningar för att ge fullskivåtkomst och kör analysen igen.", "เปิดการตั้งค่าระบบเพื่ออนุญาตการเข้าถึงดิสก์ทั้งหมด แล้วรันการวิเคราะห์อีกครั้ง", "Відкрийте Системні налаштування, щоб надати Повний доступ до диска, і запустіть аналіз знову.", "Mở Cài đặt Hệ thống để cấp Quyền truy cập Toàn bộ Đĩa, rồi chạy lại phân tích."],
    "diagnostics.section.protected": ["Защитени, но големи", "Chráněné, ale velké", "Beskyttet, men stort", "Προστατευμένα, αλλά μεγάλα", "Protegido pero voluminoso", "Suojattu, mutta suuri", "Védett, de nagy", "Dilindungi, tetapi besar", "Dilindungi, tetapi besar", "Beskyttet, men stort", "Protegido, mas volumoso", "Protejate, dar mari", "Skyddat, men stort", "ป้องกันอยู่แต่มีขนาดใหญ่", "Захищено, але велике", "Được bảo vệ nhưng lớn"],
    "diagnostics.section.rebuildable": ["Могат да се създадат отново", "Lze vytvořit znovu", "Kan genopbygges", "Μπορούν να δημιουργηθούν ξανά", "Se puede reconstruir", "Voidaan luoda uudelleen", "Újraépíthető", "Dapat dibangun ulang", "Boleh dibina semula", "Kan bygges på nytt", "Pode ser reconstruído", "Pot fi reconstruite", "Kan byggas upp igen", "สร้างใหม่ได้", "Можна відбудувати", "Có thể tạo lại"],
    "diagnostics.section.snapshots": ["Снимки", "Snímky", "Snapshots", "Στιγμιότυπα", "Instantáneas", "Tilannekuvat", "Pillanatképek", "Snapshot", "Petikan", "Øyeblikksbilder", "Instantâneos", "Instantaneuri", "Ögonblicksbilder", "สแนปชอต", "Знімки", "Ảnh chụp"],
    "diagnostics.section.skipped": ["Не можаха да бъдат прочетени", "Nebylo možné načíst", "Kunne ikke læses", "Δεν ήταν δυνατό να διαβαστούν", "No se pudo leer", "Ei voitu lukea", "Nem sikerült beolvasni", "Tidak dapat dibaca", "Tidak dapat dibaca", "Kunne ikke leses", "Não foi possível ler", "Nu au putut fi citite", "Kunde inte läsas", "อ่านไม่ได้", "Не вдалося прочитати", "Không đọc được"],
    "diagnostics.empty": ["В този обхват не беше намерено нищо голямо.", "V tomto rozsahu nebylo nalezeno nic velkého.", "Der blev ikke fundet noget stort i dette område.", "Δεν βρέθηκε κάτι μεγάλο σε αυτό το εύρος.", "No se encontró nada voluminoso en este alcance.", "Tältä alueelta ei löytynyt mitään suurta.", "Ebben a hatókörben nem található semmi nagy.", "Tidak ada yang besar ditemukan dalam cakupan ini.", "Tiada perkara besar ditemui dalam skop ini.", "Ingenting stort ble funnet i dette området.", "Não foi encontrado nada volumoso neste âmbito.", "Nu s-a găsit nimic mare în acest domeniu.", "Inget stort hittades i det här omfånget.", "ไม่พบสิ่งที่มีขนาดใหญ่ในขอบเขตนี้", "У цьому обсязі нічого великого не знайдено.", "Không tìm thấy mục nào lớn trong phạm vi này."],
    "diagnostics.note.approximate": ["Размерите са приблизителни: заради клонингите и снимките заетото място не се сумира директно.", "Velikosti jsou odhady: klony a snímky činí alokované místo nesčitatelným.", "Størrelser er skøn: kloner og snapshots gør allokeret plads ikke-additiv.", "Τα μεγέθη είναι εκτιμήσεις: τα clones και τα στιγμιότυπα κάνουν τον εκχωρημένο χώρο μη προσθετικό.", "Los tamaños son estimaciones: los clones y las instantáneas hacen que el espacio asignado no sea aditivo.", "Koot ovat arvioita: kloonit ja tilannekuvat tekevät varatusta tilasta ei-summautuvaa.", "A méretek becslések: a klónok és pillanatképek miatt a lefoglalt terület nem adható össze.", "Ukuran adalah perkiraan: klon dan snapshot membuat ruang teralokasi tidak dapat dijumlahkan.", "Saiz ialah anggaran: klon dan petikan menjadikan ruang yang diperuntukkan tidak boleh dijumlahkan.", "Størrelser er anslag: kloner og øyeblikksbilder gjør allokert plass ikke-additiv.", "Os tamanhos são estimativas: os clones e os instantâneos tornam o espaço alocado não aditivo.", "Dimensiunile sunt estimări: clonele și instantaneurile fac spațiul alocat neaditiv.", "Storlekar är uppskattningar: kloner och ögonblicksbilder gör allokerat utrymme icke-additivt.", "ขนาดเป็นค่าประมาณ: โคลนและสแนปชอตทำให้พื้นที่ที่จัดสรรไม่สามารถบวกกันได้ตรง ๆ", "Розміри приблизні: через клони й знімки виділене місце не сумується напряму.", "Kích thước là ước tính: bản sao và ảnh chụp khiến dung lượng được cấp phát không cộng dồn được."],
    "diagnostics.note.readOnly": ["Диагностиката само чете. Тук нищо не се премахва, а почистването все още минава през обичайното потвърждение.", "Diagnostika jen čte. Nic se zde neodstraňuje a čištění stále prochází běžným potvrzením.", "Diagnosen læser kun. Intet fjernes her, og en oprydning går stadig gennem den normale bekræftelse.", "Τα διαγνωστικά μόνο διαβάζουν. Τίποτα εδώ δεν αφαιρείται, και ένας καθαρισμός περνά πάντα από την κανονική επιβεβαίωση.", "El diagnóstico solo lee. Aquí no se elimina nada y cualquier limpieza pasa por la confirmación habitual.", "Diagnostiikka vain lukee. Täällä ei poisteta mitään, ja siivous kulkee edelleen tavallisen vahvistuksen kautta.", "A diagnosztika csak olvas. Itt semmi nem törlődik, a tisztítás továbbra is a szokásos megerősítéssel történik.", "Diagnostik hanya membaca. Tidak ada yang dihapus di sini, dan pembersihan tetap melalui konfirmasi biasa.", "Diagnostik hanya membaca. Tiada apa-apa di sini dibuang, dan pembersihan tetap melalui pengesahan biasa.", "Diagnostikken leser bare. Ingenting fjernes her, og en opprydding går fortsatt gjennom den vanlige bekreftelsen.", "O diagnóstico apenas lê. Nada é eliminado aqui, e qualquer limpeza passa pela confirmação habitual.", "Diagnosticarea doar citește. Nimic nu este eliminat aici, iar o curățare trece în continuare prin confirmarea obișnuită.", "Diagnostiken läser bara. Inget tas bort här, och en rensning går fortfarande via den vanliga bekräftelsen.", "การวินิจฉัยอ่านเท่านั้น ไม่มีสิ่งใดถูกลบ และการทำความสะอาดยังคงต้องผ่านการยืนยันตามปกติ", "Діагностика лише читає. Тут нічого не видаляється, а очищення й далі проходить звичайне підтвердження.", "Chẩn đoán chỉ đọc. Không có gì bị xóa ở đây và việc dọn dẹp vẫn phải qua xác nhận thông thường."],
    "files.manageScope": ["Управление в Настройки", "Spravovat v Nastavení", "Administrer i Indstillinger", "Διαχείριση στις Ρυθμίσεις", "Gestionar en Ajustes", "Hallitse asetuksissa", "Kezelés a Beállításokban", "Kelola di Pengaturan", "Urus dalam Tetapan", "Administrer i Innstillinger", "Gerir nas Definições", "Gestionează în Configurări", "Hantera i Inställningar", "จัดการในการตั้งค่า", "Керувати в Налаштуваннях", "Quản lý trong Cài đặt"],
    "settings.group.authorized": ["Разрешени папки", "Autorizované složky", "Autoriserede mapper", "Εξουσιοδοτημένοι φάκελοι", "Carpetas autorizadas", "Valtuutetut kansiot", "Engedélyezett mappák", "Folder yang diizinkan", "Folder yang dibenarkan", "Autoriserte mapper", "Pastas autorizadas", "Foldere autorizate", "Auktoriserade mappar", "โฟลเดอร์ที่อนุญาต", "Дозволені папки", "Thư mục được cho phép"],
    "settings.authorized.empty": ["Все още нищо не е разрешено. Папките, добавени тук, се сканират и се използват за търсене на дубликати.", "Zatím nebylo nic autorizováno. Složky, které zde přidáte, se skenují a používají k hledání duplikátů.", "Intet er autoriseret endnu. Mapper, du tilføjer her, scannes og bruges til at finde dubletter.", "Δεν έχει εξουσιοδοτηθεί τίποτα ακόμη. Οι φάκελοι που προσθέτετε εδώ σαρώνονται και χρησιμοποιούνται για την εύρεση διπλοτύπων.", "Aún no se autorizó nada. Las carpetas que agregues aquí se analizan y se usan para buscar duplicados.", "Mitään ei ole vielä valtuutettu. Tänne lisätyt kansiot skannataan ja niitä käytetään kaksoiskappaleiden etsimiseen.", "Még semmi nincs engedélyezve. Az itt hozzáadott mappákat vizsgálja, és a duplikátumok kereséséhez használja.", "Belum ada yang diizinkan. Folder yang Anda tambahkan di sini akan dipindai dan digunakan untuk menemukan duplikat.", "Tiada apa-apa yang dibenarkan lagi. Folder yang anda tambah di sini akan diimbas dan digunakan untuk mencari pendua.", "Ingenting er autorisert ennå. Mapper du legger til her, skannes og brukes til å finne duplikater.", "Ainda nada foi autorizado. As pastas adicionadas aqui são verificadas e utilizadas para encontrar duplicados.", "Nu a fost autorizat încă nimic. Folderele adăugate aici sunt scanate și folosite pentru a găsi duplicate.", "Inget har auktoriserats än. Mappar du lägger till här skannas och används för att hitta dubbletter.", "ยังไม่ได้อนุญาตสิ่งใด โฟลเดอร์ที่คุณเพิ่มที่นี่จะถูกสแกนและใช้ค้นหาไฟล์ซ้ำ", "Ще нічого не дозволено. Додані тут папки скануються й використовуються для пошуку дублікатів.", "Chưa có gì được cho phép. Các thư mục bạn thêm ở đây sẽ được quét và dùng để tìm tệp trùng."],
    "settings.staleThreshold": ["Праг на остаряване", "Práh zastaralosti", "Grænse for forældede filer", "Όριο παλαιότητας", "Umbral de antigüedad", "Vanhentuneiden kohteiden raja", "Elavulási küszöb", "Ambang usang", "Ambang usang", "Grense for utdaterte filer", "Limiar de antiguidade", "Prag de vechime", "Tröskel för föråldrade filer", "เกณฑ์ไฟล์ที่ไม่ได้ใช้", "Поріг застарівання", "Ngưỡng tệp cũ"],
    "storage.includeVolume": ["Включете диагностика на целия том", "Zahrnout diagnostiku celého svazku", "Medtag diagnose for hele disken", "Συμπερίληψη διαγνωστικών ολόκληρου του τόμου", "Incluir diagnóstico de todo el volumen", "Sisällytä koko levyn diagnostiikka", "Teljes kötet diagnosztikájának felvétele", "Sertakan diagnostik seluruh volume", "Sertakan diagnostik seluruh volum", "Ta med diagnostikk for hele disken", "Incluir diagnóstico do volume inteiro", "Include diagnosticarea întregului volum", "Inkludera diagnostik för hela disken", "รวมการวินิจฉัยทั้งโวลุ่ม", "Включити діагностику всього тому", "Bao gồm chẩn đoán toàn ổ đĩa"],
    "storage.scopeNote": ["Категориите файлове обхващат вашата домашна папка и разрешените папки на този диск. Превключвателят добавя диагностика на целия том.", "Kategorie souborů pokrývají vaši domovskou složku a autorizované složky na tomto disku. Přepínač přidá systémovou diagnostiku celého svazku.", "Filkategorier dækker din hjemmemappe og autoriserede mapper på denne disk. Kontakten tilføjer systemdiagnose for hele disken.", "Οι κατηγορίες αρχείων καλύπτουν τον προσωπικό σας φάκελο και τους εξουσιοδοτημένους φακέλους σε αυτόν τον δίσκο. Ο διακόπτης προσθέτει διαγνωστικά συστήματος για ολόκληρο τον τόμο.", "Las categorías de archivos abarcan tu carpeta personal y las carpetas autorizadas en este disco. La opción agrega el diagnóstico de todo el volumen.", "Tiedostokategoriat kattavat kotikansiosi ja tämän levyn valtuutetut kansiot. Kytkin lisää koko levyn järjestelmädiagnostiikan.", "A fájlkategóriák a saját mappáját és az engedélyezett mappákat fedik le ezen a lemezen. A kapcsoló hozzáadja a teljes kötet rendszerdiagnosztikáját.", "Kategori file mencakup folder home Anda dan folder yang diizinkan di disk ini. Tombol ini menambahkan diagnostik sistem seluruh volume.", "Kategori fail merangkumi folder rumah anda dan folder yang dibenarkan pada cakera ini. Suis ini menambah diagnostik sistem seluruh volum.", "Filkategoriene dekker hjemmappen din og autoriserte mapper på denne disken. Bryteren legger til systemdiagnostikk for hele disken.", "As categorias de ficheiros abrangem a sua pasta pessoal e as pastas autorizadas neste disco. A opção acrescenta o diagnóstico de todo o volume.", "Categoriile de fișiere acoperă folderul tău personal și folderele autorizate de pe acest disc. Comutatorul adaugă diagnosticarea de sistem a întregului volum.", "Filkategorierna omfattar din hemmapp och auktoriserade mappar på den här disken. Växeln lägger till systemdiagnostik för hela disken.", "หมวดหมู่ไฟล์ครอบคลุมโฟลเดอร์บ้านและโฟลเดอร์ที่อนุญาตบนดิสก์นี้ สวิตช์นี้จะเพิ่มการวินิจฉัยระบบทั้งโวลุ่ม", "Категорії файлів охоплюють вашу домашню папку й дозволені папки на цьому диску. Перемикач додає діагностику всього тому.", "Danh mục tệp bao gồm thư mục home và các thư mục được cho phép trên đĩa này. Công tắc này thêm chẩn đoán hệ thống toàn ổ đĩa."],
    "settings.authorized.unavailable": ["Не е достъпно в тази сесия", "V tomto sezení není k dispozici", "Ikke tilgængelig i denne session", "Μη διαθέσιμο σε αυτή τη συνεδρία", "No disponible en esta sesión", "Ei käytettävissä tässä istunnossa", "Ebben a munkamenetben nem érhető el", "Tidak tersedia dalam sesi ini", "Tidak tersedia dalam sesi ini", "Ikke tilgjengelig i denne økten", "Não disponível nesta sessão", "Indisponibil în această sesiune", "Inte tillgängligt i den här sessionen", "ไม่พร้อมใช้งานในเซสชันนี้", "Недоступно в цьому сеансі", "Không khả dụng trong phiên này"],
    "files.scopeTitle": ["Папки, които сте добавили", "Složky, které jste přidali", "Mapper, du har tilføjet", "Φάκελοι που προσθέσατε", "Carpetas que agregaste", "Lisäämäsi kansiot", "Az Ön által hozzáadott mappák", "Folder yang Anda tambahkan", "Folder yang anda tambah", "Mapper du har lagt til", "Pastas que adicionou", "Folderele pe care le-ai adăugat", "Mappar du har lagt till", "โฟลเดอร์ที่คุณเพิ่ม", "Додані вами папки", "Thư mục bạn đã thêm"],
    "settings.removeLicense": ["Премахнете запазения лицензионен ключ", "Odebrat uložený licenční klíč", "Fjern gemt licensnøgle", "Αφαίρεση αποθηκευμένου κλειδιού άδειας", "Eliminar la clave de licencia guardada", "Poista tallennettu lisenssiavain", "Tárolt licenckulcs eltávolítása", "Hapus kunci lisensi tersimpan", "Buang kunci lesen tersimpan", "Fjern lagret lisensnøkkel", "Remover a chave de licença guardada", "Elimină cheia de licență stocată", "Ta bort sparad licensnyckel", "ลบคีย์ลิขสิทธิ์ที่จัดเก็บไว้", "Видалити збережений ліцензійний ключ", "Xóa khóa giấy phép đã lưu"],
    "storage.title": ["Хранилище", "Úložiště", "Lagerplads", "Αποθήκευση", "Almacenamiento", "Tallennustila", "Tárhely", "Penyimpanan", "Storan", "Lagring", "Armazenamento", "Stocare", "Lagring", "พื้นที่เก็บข้อมูล", "Сховище", "Dung lượng"],
    "storage.used": ["%@ заети от %@", "%@ využito z %@", "%@ brugt af %@", "%@ σε χρήση από %@", "%@ usados de %@", "%@ käytössä %@:sta", "%@ használt a következőből: %@", "%@ terpakai dari %@", "%@ digunakan daripada %@", "%@ brukt av %@", "%@ utilizados de %@", "%@ utilizați din %@", "%@ använt av %@", "ใช้ไป %@ จาก %@", "Зайнято %@ із %@", "Đã dùng %@ trên %@"],
    "storage.byType": ["По тип файл", "Podle typu souboru", "Efter filtype", "Ανά τύπο αρχείου", "Por tipo de archivo", "Tiedostotyypeittäin", "Fájltípus szerint", "Menurut jenis file", "Mengikut jenis fail", "Etter filtype", "Por tipo de ficheiro", "După tip de fișier", "Per filtyp", "ตามชนิดไฟล์", "За типом файлів", "Theo loại tệp"],
    "storage.type.images": ["Изображения", "Obrázky", "Billeder", "Εικόνες", "Imágenes", "Kuvat", "Képek", "Gambar", "Imej", "Bilder", "Imagens", "Imagini", "Bilder", "รูปภาพ", "Зображення", "Hình ảnh"],
    "storage.type.video": ["Видео", "Video", "Video", "Βίντεο", "Video", "Video", "Videó", "Video", "Video", "Video", "Vídeo", "Video", "Video", "วิดีโอ", "Відео", "Video"],
    "storage.type.audio": ["Аудио", "Zvuk", "Lyd", "Ήχος", "Audio", "Ääni", "Hang", "Audio", "Audio", "Lyd", "Áudio", "Audio", "Ljud", "เสียง", "Аудіо", "Âm thanh"],
    "storage.type.documents": ["Документи", "Dokumenty", "Dokumenter", "Έγγραφα", "Documentos", "Asiakirjat", "Dokumentumok", "Dokumen", "Dokumen", "Dokumenter", "Documentos", "Documente", "Dokument", "เอกสาร", "Документи", "Tài liệu"],
    "storage.type.archives": ["Архиви", "Archivy", "Arkiver", "Αρχεία συμπίεσης", "Archivos comprimidos", "Arkistot", "Archívumok", "Arsip", "Arkib", "Arkiver", "Ficheiros comprimidos", "Arhive", "Arkiv", "ไฟล์บีบอัด", "Архіви", "Tệp nén"],
    "storage.type.code": ["Код", "Kód", "Kode", "Κώδικας", "Código", "Koodi", "Kód", "Kode", "Kod", "Kode", "Código", "Cod", "Kod", "โค้ด", "Код", "Mã"],
    "storage.type.data": ["Данни", "Data", "Data", "Δεδομένα", "Datos", "Tiedot", "Adatok", "Data", "Data", "Data", "Dados", "Date", "Data", "ข้อมูล", "Дані", "Dữ liệu"],
    "storage.type.other": ["Друго", "Ostatní", "Andet", "Άλλα", "Otros", "Muut", "Egyéb", "Lainnya", "Lain-lain", "Annet", "Outros", "Altele", "Övrigt", "อื่น ๆ", "Інше", "Khác"],
    "storage.topFiles": ["Най-големи файлове", "Největší soubory", "Største filer", "Μεγαλύτερα αρχεία", "Archivos más grandes", "Suurimmat tiedostot", "Legnagyobb fájlok", "File terbesar", "Fail terbesar", "Største filer", "Ficheiros maiores", "Cele mai mari fișiere", "Största filerna", "ไฟล์ที่ใหญ่ที่สุด", "Найбільші файли", "Tệp lớn nhất"],
    "storage.topDirectories": ["Най-големи папки", "Největší složky", "Største mapper", "Μεγαλύτεροι φάκελοι", "Carpetas más grandes", "Suurimmat kansiot", "Legnagyobb mappák", "Folder terbesar", "Folder terbesar", "Største mapper", "Pastas maiores", "Cele mai mari foldere", "Största mapparna", "โฟลเดอร์ที่ใหญ่ที่สุด", "Найбільші папки", "Thư mục lớn nhất"],
    "storage.analyze": ["Анализирайте хранилището", "Analyzovat úložiště", "Analyser lagerplads", "Ανάλυση αποθήκευσης", "Analizar almacenamiento", "Analysoi tallennustila", "Tárhely elemzése", "Analisis penyimpanan", "Analisis storan", "Analyser lagring", "Analisar armazenamento", "Analizează stocarea", "Analysera lagring", "วิเคราะห์พื้นที่เก็บข้อมูล", "Проаналізувати сховище", "Phân tích dung lượng"],
    "storage.start": ["Стартирайте анализа", "Spustit analýzu", "Start analyse", "Έναρξη ανάλυσης", "Iniciar análisis", "Aloita analyysi", "Elemzés indítása", "Mulai analisis", "Mula analisis", "Start analyse", "Iniciar análise", "Începe analiza", "Starta analys", "เริ่มการวิเคราะห์", "Почати аналіз", "Bắt đầu phân tích"],
    "storage.reanalyze": ["Анализирайте отново", "Analyzovat znovu", "Analyser igen", "Νέα ανάλυση", "Analizar de nuevo", "Analysoi uudelleen", "Újraelemzés", "Analisis lagi", "Analisis semula", "Analyser igjen", "Analisar novamente", "Analizează din nou", "Analysera igen", "วิเคราะห์อีกครั้ง", "Проаналізувати знову", "Phân tích lại"],
    "storage.cancelAnalysis": ["Отменете анализа", "Zrušit analýzu", "Annuller analyse", "Ακύρωση ανάλυσης", "Cancelar análisis", "Peruuta analyysi", "Elemzés megszakítása", "Batalkan analisis", "Batal analisis", "Avbryt analyse", "Cancelar análise", "Anulează analiza", "Avbryt analys", "ยกเลิกการวิเคราะห์", "Скасувати аналіз", "Hủy phân tích"],
    "storage.lastAnalyzed": ["Последен анализ: %@", "Poslední analýza %@", "Senest analyseret %@", "Τελευταία ανάλυση: %@", "Último análisis: %@", "Viimeksi analysoitu %@", "Utolsó elemzés: %@", "Terakhir dianalisis %@", "Terakhir dianalisis %@", "Sist analysert %@", "Última análise: %@", "Ultima analiză %@", "Senast analyserad %@", "วิเคราะห์ล่าสุด %@", "Останній аналіз: %@", "Phân tích lần cuối %@"],
    "storage.analysing": ["Анализиране…", "Analýza…", "Analyserer…", "Γίνεται ανάλυση…", "Analizando…", "Analysoidaan…", "Elemzés…", "Menganalisis…", "Menganalisis…", "Analyserer…", "A analisar…", "Se analizează…", "Analyserar…", "กำลังวิเคราะห์…", "Аналіз…", "Đang phân tích…"],
    "storage.diskDisconnected": ["Този диск вече не е свързан. Свържете го отново и сканирайте.", "Tento disk už není připojen. Připojte jej a skenujte znovu.", "Denne disk er ikke længere tilsluttet. Tilslut den igen, og scan igen.", "Αυτός ο δίσκος δεν είναι πλέον συνδεδεμένος. Συνδέστε τον ξανά και σαρώστε εκ νέου.", "Este disco ya no está conectado. Vuelve a conectarlo y analiza de nuevo.", "Tätä levyä ei ole enää liitetty. Liitä se uudelleen ja skannaa uudelleen.", "Ez a lemez már nincs csatlakoztatva. Csatlakoztassa újra, és vizsgálja meg újra.", "Disk ini tidak lagi terhubung. Hubungkan kembali dan pindai lagi.", "Cakera ini tidak lagi disambungkan. Sambung semula dan imbas semula.", "Denne disken er ikke lenger tilkoblet. Koble den til igjen og skann på nytt.", "Este disco já não está ligado. Ligue-o novamente e verifique outra vez.", "Acest disc nu mai este conectat. Reconectează-l și scanează din nou.", "Den här disken är inte längre ansluten. Anslut den igen och skanna på nytt.", "ดิสก์นี้ไม่ได้เชื่อมต่ออยู่แล้ว เชื่อมต่อใหม่แล้วสแกนอีกครั้ง", "Цей диск більше не під'єднано. Під'єднайте його знову й скануйте.", "Đĩa này không còn kết nối. Hãy kết nối lại và quét lại."],
    "storage.noAccess": ["Sift все още не може да прочете това място.", "Sift zatím toto místo nemůže načíst.", "Sift kan ikke læse denne placering endnu.", "Το Sift δεν μπορεί να διαβάσει ακόμη αυτή την τοποθεσία.", "Sift aún no puede leer esta ubicación.", "Sift ei voi vielä lukea tätä sijaintia.", "A Sift egyelőre nem tudja beolvasni ezt a helyet.", "Sift belum dapat membaca lokasi ini.", "Sift belum boleh membaca lokasi ini.", "Sift kan ikke lese dette stedet ennå.", "O Sift ainda não consegue ler este local.", "Sift nu poate citi încă această locație.", "Sift kan inte läsa den här platsen än.", "Sift ยังอ่านตำแหน่งนี้ไม่ได้", "Sift поки не може прочитати це місце.", "Sift chưa thể đọc vị trí này."],
    "settings.title": ["Настройки", "Nastavení", "Indstillinger", "Ρυθμίσεις", "Ajustes", "Asetukset", "Beállítások", "Pengaturan", "Tetapan", "Innstillinger", "Definições", "Configurări", "Inställningar", "การตั้งค่า", "Налаштування", "Cài đặt"],
    "settings.group.scanScope": ["Обхват на сканиране", "Rozsah skenování", "Scanningsområde", "Εύρος σάρωσης", "Alcance del análisis", "Skannausalue", "Vizsgálat hatóköre", "Cakupan pemindaian", "Skop imbasan", "Skanningsområde", "Âmbito da verificação", "Domeniu de scanare", "Skanningsomfång", "ขอบเขตการสแกน", "Обсяг сканування", "Phạm vi quét"],
    "settings.group.thresholds": ["Прагове", "Prahy", "Grænseværdier", "Όρια", "Umbrales", "Rajat", "Küszöbök", "Ambang", "Ambang", "Grenseverdier", "Limiares", "Praguri", "Tröskelvärden", "เกณฑ์", "Пороги", "Ngưỡng"],
    "settings.group.ignores": ["Игнорирани елементи", "Ignorované položky", "Ignorerede elementer", "Στοιχεία που αγνοούνται", "Elementos ignorados", "Huomiotta jätetyt kohteet", "Figyelmen kívül hagyott elemek", "Item yang diabaikan", "Item diabaikan", "Ignorerte elementer", "Itens ignorados", "Elemente ignorate", "Ignorerade objekt", "รายการที่ไม่สนใจ", "Ігноровані елементи", "Mục bị bỏ qua"],
    "settings.group.confirmation": ["Потвърждение", "Potvrzení", "Bekræftelse", "Επιβεβαίωση", "Confirmación", "Vahvistus", "Megerősítés", "Konfirmasi", "Pengesahan", "Bekreftelse", "Confirmação", "Confirmare", "Bekräftelse", "การยืนยัน", "Підтвердження", "Xác nhận"],
    "settings.group.appearance": ["Изглед", "Vzhled", "Udseende", "Εμφάνιση", "Apariencia", "Ulkoasu", "Megjelenés", "Tampilan", "Penampilan", "Utseende", "Aparência", "Aspect", "Utseende", "รูปลักษณ์", "Вигляд", "Giao diện"],
    "settings.group.language": ["Език", "Jazyk", "Sprog", "Γλώσσα", "Idioma", "Kieli", "Nyelv", "Bahasa", "Bahasa", "Språk", "Idioma", "Limbă", "Språk", "ภาษา", "Мова", "Ngôn ngữ"],
    "settings.group.privacy": ["Поверителност", "Soukromí", "Anonymitet", "Απόρρητο", "Privacidad", "Tietosuoja", "Adatvédelem", "Privasi", "Privasi", "Personvern", "Privacidade", "Confidențialitate", "Integritet", "ความเป็นส่วนตัว", "Конфіденційність", "Quyền riêng tư"],
    "settings.group.purchase": ["Покупка", "Zakoupení", "Køb", "Αγορά", "Compra", "Osto", "Vásárlás", "Pembelian", "Pembelian", "Kjøp", "Compra", "Achiziție", "Köp", "การซื้อ", "Покупка", "Mua hàng"],
    "settings.group.logs": ["Диагностика", "Diagnostika", "Diagnose", "Διαγνωστικά", "Diagnósticos", "Diagnostiikka", "Diagnosztika", "Diagnostik", "Diagnostik", "Diagnostikk", "Diagnósticos", "Diagnosticare", "Diagnostik", "การวินิจฉัย", "Діагностика", "Chẩn đoán"],
    "settings.largeFileThreshold": ["Праг за големи файлове", "Práh velkého souboru", "Grænse for store filer", "Όριο μεγάλων αρχείων", "Umbral de archivos grandes", "Suurten tiedostojen raja", "Nagy fájl küszöb", "Ambang file besar", "Ambang fail besar", "Grense for store filer", "Limiar de ficheiros grandes", "Prag fișiere mari", "Tröskel för stora filer", "เกณฑ์ไฟล์ขนาดใหญ่", "Поріг великих файлів", "Ngưỡng tệp lớn"],
    "settings.oldFileThreshold": ["Праг за стари файлове", "Práh starého souboru", "Grænse for gamle filer", "Όριο παλιών αρχείων", "Umbral de archivos antiguos", "Vanhojen tiedostojen raja", "Régi fájl küszöb", "Ambang file lama", "Ambang fail lama", "Grense for gamle filer", "Limiar de ficheiros antigos", "Prag fișiere vechi", "Tröskel för gamla filer", "เกณฑ์ไฟล์เก่า", "Поріг старих файлів", "Ngưỡng tệp cũ"],
    "settings.days": ["%d дни", "%d dní", "%d dage", "%d ημέρες", "%d días", "%d päivää", "%d nap", "%d hari", "%d hari", "%d dager", "%d dias", "%d zile", "%d dagar", "%d วัน", "%d днів", "%d ngày"],
    "settings.showHiddenFiles": ["Показвайте скрити файлове в резултатите", "Zobrazovat skryté soubory ve výsledcích", "Vis skjulte filer i resultater", "Εμφάνιση κρυφών αρχείων στα αποτελέσματα", "Mostrar archivos ocultos en los resultados", "Näytä piilotetut tiedostot tuloksissa", "Rejtett fájlok megjelenítése az eredményekben", "Tampilkan file tersembunyi di hasil", "Tunjukkan fail tersembunyi dalam hasil", "Vis skjulte filer i resultatene", "Mostrar ficheiros ocultos nos resultados", "Arată fișierele ascunse în rezultate", "Visa dolda filer i resultaten", "แสดงไฟล์ที่ซ่อนอยู่ในผลลัพธ์", "Показувати приховані файли в результатах", "Hiện tệp ẩn trong kết quả"],
    "settings.userRules": ["Използвайте собствен файл с правила", "Použít vlastní soubor pravidel", "Brug en brugerdefineret regelfil", "Χρήση προσαρμοσμένου αρχείου κανόνων", "Usar un archivo de reglas personalizado", "Käytä mukautettua sääntötiedostoa", "Egyéni szabályfájl használata", "Gunakan file aturan khusus", "Gunakan fail peraturan tersuai", "Bruk en egendefinert regelfil", "Utilizar um ficheiro de regras personalizado", "Folosește un fișier de reguli personalizat", "Använd en egen regelfil", "ใช้ไฟล์กฎที่กำหนดเอง", "Використовувати власний файл правил", "Dùng tệp quy tắc tùy chỉnh"],
    "settings.userRulesDetail": ["Чете CleaningRules.json от папката с данни на приложението. Прилага се от следващото сканиране.", "Načte CleaningRules.json ze složky s daty aplikace. Projeví se při příštím skenování.", "Læser CleaningRules.json fra appens datamappe. Gælder fra næste scanning.", "Διαβάζει το CleaningRules.json από τον φάκελο δεδομένων της εφαρμογής. Ισχύει από την επόμενη σάρωση.", "Lee CleaningRules.json de la carpeta de datos de la aplicación. Se aplica al próximo análisis.", "Lukee CleaningRules.json-tiedoston sovelluksen datakansiosta. Tulee voimaan seuraavassa skannauksessa.", "A CleaningRules.json fájlt olvassa az alkalmazás adatmappájából. A következő vizsgálatnál lép életbe.", "Membaca CleaningRules.json dari folder data aplikasi. Berlaku untuk pemindaian berikutnya.", "Membaca CleaningRules.json daripada folder data apl. Terpakai pada imbasan seterusnya.", "Leser CleaningRules.json fra appens datamappe. Gjelder fra neste skanning.", "Lê o CleaningRules.json da pasta de dados da aplicação. Aplica-se à próxima verificação.", "Citește CleaningRules.json din folderul de date al aplicației. Se aplică la următoarea scanare.", "Läser CleaningRules.json från appens datamapp. Gäller från nästa skanning.", "อ่าน CleaningRules.json จากโฟลเดอร์ข้อมูลของแอป มีผลกับการสแกนครั้งถัดไป", "Читає CleaningRules.json із папки даних програми. Застосовується з наступного сканування.", "Đọc CleaningRules.json từ thư mục dữ liệu của ứng dụng. Áp dụng cho lần quét tiếp theo."],
    "settings.requireConfirmation": ["Питайте за потвърждение преди почистване", "Před čištěním žádat potvrzení", "Spørg om bekræftelse før oprydning", "Ερώτηση επιβεβαίωσης πριν από τον καθαρισμό", "Pedir confirmación antes de limpiar", "Kysy vahvistus ennen siivousta", "Tisztítás előtti megerősítés kérése", "Minta konfirmasi sebelum membersihkan", "Minta pengesahan sebelum membersihkan", "Spør om bekreftelse før opprydding", "Pedir confirmação antes de limpar", "Cere confirmare înainte de curățare", "Fråga efter bekräftelse innan rensning", "ถามเพื่อยืนยันก่อนทำความสะอาด", "Питати підтвердження перед очищенням", "Hỏi xác nhận trước khi dọn dẹp"],
    "settings.skipConfirmation": ["Пропускайте потвърждението", "Přeskočit potvrzení", "Spring bekræftelse over", "Παράλειψη επιβεβαίωσης", "Omitir confirmación", "Ohita vahvistus", "Megerősítés kihagyása", "Lewati konfirmasi", "Langkau pengesahan", "Hopp over bekreftelse", "Ignorar confirmação", "Omite confirmarea", "Hoppa över bekräftelse", "ข้ามการยืนยัน", "Пропускати підтвердження", "Bỏ qua xác nhận"],
    "settings.skipConfirmationWarning": ["Sift започва почистване веднага щом натиснете. Елементите все още отиват в Кошчето, но няма да видите списъка първо. Елементите, отбелязани за преглед, винаги показват списъка.", "Sift začne čistit hned po kliknutí. Položky stále jdou do Koše, ale seznam nejprve neuvidíte. Položky označené ke kontrole vždy zobrazí seznam.", "Sift rydder, så snart du klikker. Elementerne ryger stadig i Papirkurven, men du ser ikke listen først. Elementer markeret til gennemgang viser altid listen.", "Το Sift ξεκινά τον καθαρισμό μόλις κάνετε κλικ. Τα στοιχεία πηγαίνουν πάντα στον Κάδο, αλλά δεν θα δείτε πρώτα τη λίστα. Τα στοιχεία που έχουν χαρακτηριστεί προς έλεγχο εμφανίζουν πάντα τη λίστα.", "Sift limpia en cuanto haces clic. Los elementos siguen yendo a la Papelera, pero no verás la lista antes. Los elementos marcados para revisar siempre muestran la lista.", "Sift siivoaa heti, kun napsautat. Kohteet siirtyvät silti Roskakoriin, mutta et näe luetteloa ensin. Tarkistettaviksi merkityt kohteet näyttävät aina luettelon.", "A Sift a kattintás után azonnal tisztítani kezd. Az elemek továbbra is a Kukába kerülnek, de előbb nem látja a listát. Az átnézendőnek jelölt elemek mindig megjelenítik a listát.", "Sift membersihkan begitu Anda mengeklik. Item tetap dipindahkan ke Tempat Sampah, tetapi Anda tidak akan melihat daftarnya lebih dulu. Item yang ditandai untuk ditinjau selalu menampilkan daftar.", "Sift mula membersihkan sebaik sahaja anda mengklik. Item tetap masuk ke Tong Sampah, tetapi anda tidak akan melihat senarai terlebih dahulu. Item yang ditanda untuk disemak sentiasa memaparkan senarai.", "Sift begynner å rydde så snart du klikker. Elementene går fortsatt til Papirkurven, men du ser ikke listen først. Elementer merket for gjennomgang viser alltid listen.", "O Sift começa a limpar assim que clicar. Os itens continuam a ir para o Lixo, mas não verá a lista primeiro. Os itens marcados para revisão mostram sempre a lista.", "Sift începe curățarea imediat ce faci clic. Elementele ajung tot în Coș, dar nu vei vedea lista mai întâi. Elementele marcate pentru verificare afișează întotdeauna lista.", "Sift börjar rensa så snart du klickar. Objekten hamnar fortfarande i Papperskorgen, men du ser inte listan först. Objekt markerade för granskning visar alltid listan.", "Sift จะเริ่มทำความสะอาดทันทีที่คุณคลิก รายการยังถูกย้ายไปที่ถังขยะ แต่คุณจะไม่เห็นรายการก่อน รายการที่ทำเครื่องหมายว่าควรตรวจสอบจะแสดงรายการเสมอ", "Sift почне очищення одразу після натискання. Елементи все одно перейдуть у Кошик, але списку ви не побачите. Елементи, позначені для перевірки, завжди показують список.", "Sift bắt đầu dọn dẹp ngay khi bạn nhấp. Các mục vẫn được chuyển vào Thùng rác nhưng bạn sẽ không thấy danh sách trước. Các mục được đánh dấu cần xem lại luôn hiển thị danh sách."],
    "settings.appearance.system": ["Както в системата", "Podle systému", "Følg systemet", "Όπως το σύστημα", "Seguir al sistema", "Seuraa järjestelmää", "Rendszer követése", "Ikuti sistem", "Ikut sistem", "Følg systemet", "Seguir o sistema", "Urmează sistemul", "Följ systemet", "ตามระบบ", "Як у системі", "Theo hệ thống"],
    "settings.appearance.light": ["Светъл", "Světlý", "Lys", "Φωτεινό", "Claro", "Vaalea", "Világos", "Terang", "Cerah", "Lys", "Claro", "Luminoasă", "Ljust", "สว่าง", "Світлий", "Sáng"],
    "settings.appearance.dark": ["Тъмен", "Tmavý", "Mørk", "Σκοτεινό", "Oscuro", "Tumma", "Sötét", "Gelap", "Gelap", "Mørk", "Escuro", "Întunecată", "Mörkt", "มืด", "Темний", "Tối"],
    "settings.reduceMotion": ["Намалете движението", "Omezit pohyb", "Reducer bevægelse", "Μείωση κίνησης", "Reducir movimiento", "Vähennä liikettä", "Mozgás csökkentése", "Kurangi gerak", "Kurangkan gerakan", "Reduser bevegelse", "Reduzir movimento", "Reduce mișcarea", "Minska rörelse", "ลดการเคลื่อนไหว", "Зменшити рух", "Giảm chuyển động"],
    "settings.privacyStatement": ["Sift не събира съдържание на файлове, имена на файлове, пълни пътища, история на сърфиране, използване на приложения или данни за акаунт. Резултатите от сканирането остават на този Mac и нищо не се качва.", "Sift neshromažďuje obsah souborů, názvy souborů, úplné cesty, historii prohlížení, používání aplikací ani údaje o účtu. Výsledky skenování zůstávají na tomto Macu a nic se neodesílá.", "Sift indsamler ikke filindhold, filnavne, fulde stier, browserhistorik, appforbrug eller kontooplysninger. Scanningsresultater bliver på denne Mac, og intet uploades.", "Το Sift δεν συλλέγει περιεχόμενα αρχείων, ονόματα αρχείων, πλήρεις διαδρομές, ιστορικό περιήγησης, χρήση εφαρμογών ή στοιχεία λογαριασμού. Τα αποτελέσματα της σάρωσης παραμένουν σε αυτό το Mac και τίποτα δεν μεταφορτώνεται.", "Sift no recopila contenidos de archivos, nombres de archivos, rutas completas, historial de navegación, uso de aplicaciones ni datos de cuenta. Los resultados del análisis se quedan en este Mac y no se sube nada.", "Sift ei kerää tiedostojen sisältöä, tiedostonimiä, täydellisiä polkuja, selaushistoriaa, sovellusten käyttöä tai tilitietoja. Skannaustulokset pysyvät tällä Macilla, eikä mitään ladata.", "A Sift nem gyűjt fájltartalmat, fájlneveket, teljes elérési utakat, böngészési előzményeket, alkalmazáshasználatot vagy fiókadatokat. A vizsgálati eredmények ezen a Macen maradnak, és semmi nem kerül feltöltésre.", "Sift tidak mengumpulkan konten file, nama file, jalur lengkap, riwayat penjelajahan, penggunaan aplikasi, atau detail akun. Hasil pemindaian tetap di Mac ini, dan tidak ada yang diunggah.", "Sift tidak mengumpul kandungan fail, nama fail, laluan penuh, sejarah pelayaran, penggunaan apl atau butiran akaun. Hasil imbasan kekal pada Mac ini, dan tiada apa-apa dimuat naik.", "Sift samler ikke inn filinnhold, filnavn, fulle stier, nettleserhistorikk, appbruk eller kontoopplysninger. Skanneresultatene blir på denne Macen, og ingenting lastes opp.", "O Sift não recolhe conteúdos de ficheiros, nomes de ficheiros, caminhos completos, histórico de navegação, utilização de aplicações nem dados de conta. Os resultados da verificação ficam neste Mac e nada é enviado.", "Sift nu colectează conținutul fișierelor, numele fișierelor, căi complete, istoricul de navigare, utilizarea aplicațiilor sau detalii de cont. Rezultatele scanării rămân pe acest Mac și nimic nu este încărcat.", "Sift samlar inte in filinnehåll, filnamn, fullständiga sökvägar, webbläsarhistorik, appanvändning eller kontouppgifter. Skanningsresultaten stannar på den här Macen och inget laddas upp.", "Sift ไม่เก็บเนื้อหาไฟล์ ชื่อไฟล์ เส้นทางแบบเต็ม ประวัติการท่องเว็บ การใช้งานแอป หรือรายละเอียดบัญชี ผลการสแกนอยู่ใน Mac เครื่องนี้ และไม่มีสิ่งใดถูกอัปโหลด", "Sift не збирає вміст файлів, назви файлів, повні шляхи, історію перегляду, дані про використання програм чи дані облікового запису. Результати сканування залишаються на цьому Mac, і нічого не завантажується.", "Sift không thu thập nội dung tệp, tên tệp, đường dẫn đầy đủ, lịch sử duyệt web, việc sử dụng ứng dụng hay chi tiết tài khoản. Kết quả quét ở lại trên Mac này và không có gì được tải lên."],
    "settings.exportLogs": ["Експортирайте диагностиката", "Exportovat diagnostiku", "Eksporter diagnose", "Εξαγωγή διαγνωστικών", "Exportar diagnósticos", "Vie diagnostiikka", "Diagnosztika exportálása", "Ekspor diagnostik", "Eksport diagnostik", "Eksporter diagnostikk", "Exportar diagnósticos", "Exportă diagnosticarea", "Exportera diagnostik", "ส่งออกข้อมูลวินิจฉัย", "Експортувати діагностику", "Xuất chẩn đoán"],
    "settings.exportLogsDetail": ["Диагностиката не съдържа имена на файлове или пълни пътища.", "Diagnostika neobsahuje názvy souborů ani úplné cesty.", "Diagnosedata indeholder ingen filnavne eller fulde stier.", "Τα διαγνωστικά δεν περιέχουν ονόματα αρχείων ή πλήρεις διαδρομές.", "Los diagnósticos no contienen nombres de archivos ni rutas completas.", "Diagnostiikka ei sisällä tiedostonimiä tai täydellisiä polkuja.", "A diagnosztika nem tartalmaz fájlneveket vagy teljes elérési utakat.", "Diagnostik tidak berisi nama file atau jalur lengkap.", "Diagnostik tidak mengandungi nama fail atau laluan penuh.", "Diagnostikken inneholder ingen filnavn eller fulle stier.", "Os diagnósticos não contêm nomes de ficheiros nem caminhos completos.", "Diagnosticarea nu conține nume de fișiere sau căi complete.", "Diagnostiken innehåller inga filnamn eller fullständiga sökvägar.", "ข้อมูลวินิจฉัยไม่มีชื่อไฟล์หรือเส้นทางแบบเต็ม", "Діагностика не містить назв файлів чи повних шляхів.", "Chẩn đoán không chứa tên tệp hay đường dẫn đầy đủ."],
    "settings.clearHistory": ["Изчистете историята на сканиранията", "Vymazat historii skenování", "Ryd scanningshistorik", "Διαγραφή ιστορικού σαρώσεων", "Borrar historial de análisis", "Tyhjennä skannaushistoria", "Vizsgálati előzmények törlése", "Hapus riwayat pemindaian", "Kosongkan sejarah imbasan", "Tøm skannehistorikken", "Apagar histórico de verificações", "Șterge istoricul scanărilor", "Rensa skanningshistoriken", "ล้างประวัติการสแกน", "Очистити історію сканувань", "Xóa lịch sử quét"],
    "settings.deleteReports": ["Изтрийте запазените отчети", "Smazat uložené zprávy", "Slet gemte rapporter", "Διαγραφή αποθηκευμένων αναφορών", "Eliminar informes guardados", "Poista tallennetut raportit", "Mentett jelentések törlése", "Hapus laporan tersimpan", "Padam laporan tersimpan", "Slett lagrede rapporter", "Eliminar relatórios guardados", "Șterge rapoartele salvate", "Radera sparade rapporter", "ลบรายงานที่บันทึกไว้", "Видалити збережені звіти", "Xóa báo cáo đã lưu"],
    "settings.deleteReportsConfirm": ["Да се изтрият ли всички запазени PDF отчети? Това не може да бъде отменено.", "Smazat všechny uložené zprávy PDF? Tuto akci nelze vrátit.", "Slet alle gemte PDF-rapporter? Dette kan ikke fortrydes.", "Διαγραφή όλων των αποθηκευμένων αναφορών PDF; Η ενέργεια δεν αναιρείται.", "¿Eliminar todos los informes PDF guardados? Esta acción no se puede deshacer.", "Poistetaanko kaikki tallennetut PDF-raportit? Tätä ei voi kumota.", "Törli az összes mentett PDF-jelentést? Ez nem vonható vissza.", "Hapus semua laporan PDF tersimpan? Tindakan ini tidak dapat dibatalkan.", "Padam semua laporan PDF tersimpan? Tindakan ini tidak boleh dibatalkan.", "Slette alle lagrede PDF-rapporter? Dette kan ikke angres.", "Eliminar todos os relatórios PDF guardados? Esta ação não pode ser anulada.", "Ștergi toate rapoartele PDF salvate? Această acțiune nu poate fi anulată.", "Radera alla sparade PDF-rapporter? Detta kan inte ångras.", "ลบรายงาน PDF ที่บันทึกไว้ทั้งหมดหรือไม่ การกระทำนี้ไม่สามารถย้อนกลับได้", "Видалити всі збережені PDF-звіти? Цю дію не можна скасувати.", "Xóa tất cả báo cáo PDF đã lưu? Không thể hoàn tác thao tác này."],
    "settings.resetDefaults": ["Възстановете настройките по подразбиране", "Obnovit výchozí hodnoty", "Gendan standardindstillinger", "Επαναφορά προεπιλογών", "Restaurar valores predeterminados", "Palauta oletukset", "Alapértelmezések visszaállítása", "Pulihkan default", "Pulihkan lalai", "Gjenopprett standardinnstillinger", "Repor predefinições", "Restaurează valorile implicite", "Återställ standardvärden", "คืนค่าเริ่มต้น", "Відновити типові значення", "Khôi phục mặc định"],
    "purchase.title": ["Отключете Sift", "Odemknout Sift", "Lås Sift op", "Ξεκλείδωμα του Sift", "Desbloquear Sift", "Avaa Sift käyttöön", "A Sift feloldása", "Buka Sift", "Buka Sift", "Lås opp Sift", "Desbloquear o Sift", "Deblochează Sift", "Lås upp Sift", "ปลดล็อก Sift", "Розблокувати Sift", "Mở khóa Sift"],
    "purchase.priceLine": ["$4.99 еднократно, завинаги ваше, без абонамент", "4,99 USD jednorázově, navždy vaše, bez předplatného", "4,99 $ én gang, dit for altid, intet abonnement", "4,99 $ μία φορά, για πάντα, χωρίς συνδρομή", "US$ 4,99 una vez, para siempre, sin suscripción", "4,99 $ kertaostoksena, ikuisesti sinun, ei tilausta", "4,99 USD egyszeri díj, örökre az Öné, előfizetés nélkül", "$4.99 sekali bayar, milik Anda selamanya, tanpa langganan", "$4.99 sekali bayar, milik anda selamanya, tiada langganan", "4,99 $ én gang, ditt for alltid, uten abonnement", "4,99 US$ uma vez, para sempre, sem subscrição", "4,99 USD o singură dată, pentru totdeauna, fără abonament", "4,99 $ en gång, ditt för alltid, ingen prenumeration", "$4.99 ครั้งเดียว ใช้ได้ตลอดไป ไม่มีค่าสมาชิก", "$4.99 одноразово, назавжди ваше, без підписки", "$4.99 một lần, dùng mãi mãi, không đăng ký định kỳ"],
    "purchase.updatesPromise": ["Включва бъдещи големи актуализации.", "Zahrnuje budoucí hlavní aktualizace.", "Omfatter fremtidige hovedopdateringer.", "Περιλαμβάνει μελλοντικές κύριες ενημερώσεις.", "Incluye futuras actualizaciones importantes.", "Sisältää tulevat pääpäivitykset.", "Tartalmazza a jövőbeli fő frissítéseket.", "Termasuk pembaruan utama di masa mendatang.", "Termasuk kemas kini utama pada masa hadapan.", "Inkluderer fremtidige hovedoppdateringer.", "Inclui futuras atualizações principais.", "Include actualizările majore viitoare.", "Inkluderar framtida huvuduppdateringar.", "รวมการอัปเดตเวอร์ชันหลักในอนาคต", "Включає майбутні великі оновлення.", "Bao gồm các bản cập nhật lớn trong tương lai."],
    "purchase.freeTier.scan": ["Сканирайте целия си Mac", "Skenovat celý Mac", "Scan hele din Mac", "Σάρωση ολόκληρου του Mac", "Analizar todo tu Mac", "Skannaa koko Mac", "A teljes Mac vizsgálata", "Pindai seluruh Mac Anda", "Imbas seluruh Mac anda", "Skann hele Macen", "Verificar todo o Mac", "Scanează tot Macul", "Skanna hela din Mac", "สแกน Mac ทั้งเครื่อง", "Сканувати весь свій Mac", "Quét toàn bộ Mac của bạn"],
    "purchase.freeTier.explain": ["Вижте всеки елемент, неговия източник и риск", "Zobrazit každou položku, její zdroj a riziko", "Se hvert element, dets kilde og risiko", "Προβολή κάθε στοιχείου, της πηγής και του κινδύνου του", "Ver cada elemento, su origen y su riesgo", "Näe jokainen kohde, sen lähde ja riski", "Minden elem, forrása és kockázata megtekintése", "Lihat setiap item, sumber, dan risikonya", "Lihat setiap item, sumber dan risikonya", "Se hvert element, kilden og risikoen", "Ver cada item, a sua origem e o seu risco", "Vezi fiecare element, sursa și riscul lui", "Se varje objekt, dess källa och risk", "ดูทุกรายการ แหล่งที่มา และระดับความเสี่ยง", "Бачити кожен елемент, його джерело й ризик", "Xem mọi mục, nguồn gốc và mức rủi ro"],
    "purchase.freeTier.estimate": ["Вижте колко място можете да освободите", "Zjistit, kolik místa můžete uvolnit", "Se, hvor meget plads du kan frigive", "Προβολή του χώρου που θα μπορούσατε να ελευθερώσετε", "Ver cuánto espacio podrías liberar", "Näe, kuinka paljon tilaa voisit vapauttaa", "Annak megtekintése, mennyi hely szabadítható fel", "Lihat berapa banyak ruang yang dapat Anda bebaskan", "Lihat berapa banyak ruang yang boleh anda lepaskan", "Se hvor mye plass du kan frigjøre", "Ver quanto espaço pode libertar", "Vezi cât spațiu ai putea elibera", "Se hur mycket utrymme du kan frigöra", "ดูว่าคุณปลดปล่อยพื้นที่ได้เท่าไร", "Побачити, скільки місця можна звільнити", "Xem bạn có thể giải phóng bao nhiêu dung lượng"],
    "purchase.freeTier.storage": ["Анализирайте хранилището по тип и папка", "Analyzovat úložiště podle typu a složky", "Analyser lagerplads efter type og mappe", "Ανάλυση αποθήκευσης ανά τύπο και φάκελο", "Analizar el almacenamiento por tipo y carpeta", "Analysoi tallennustila tyypeittäin ja kansoittain", "A tárhely elemzése típus és mappa szerint", "Analisis penyimpanan menurut jenis dan folder", "Analisis storan mengikut jenis dan folder", "Analyser lagring etter type og mappe", "Analisar o armazenamento por tipo e por pasta", "Analizează stocarea după tip și folder", "Analysera lagring per typ och mapp", "วิเคราะห์พื้นที่เก็บข้อมูลตามชนิดและโฟลเดอร์", "Аналізувати сховище за типом і папкою", "Phân tích dung lượng theo loại và thư mục"],
    "purchase.paidTierTitle": ["Какво добавя отключването", "Co odemknutí přidá", "Det tilføjer oplåsningen", "Τι προσθέτει το ξεκλείδωμα", "Lo que agrega el desbloqueo", "Tämän avaaminen lisää", "Mit ad hozzá a feloldás", "Yang ditambahkan oleh pembukaan kunci", "Apa yang ditambah oleh pembukaan kunci", "Dette legger opplåsingen til", "O que o desbloqueio acrescenta", "Ce adaugă deblocarea", "Det här tillför upplåsningen", "สิ่งที่การปลดล็อกเพิ่มให้", "Що додає розблокування", "Những gì mở khóa bổ sung"],
    "purchase.paidTier.clean": ["Преместете кешове, журнали и инсталатори в Кошчето", "Přesunout mezipaměti, protokoly a instalátory do Koše", "Flyt caches, logfiler og installationsprogrammer til Papirkurven", "Μετακίνηση cache, αρχείων καταγραφής και προγραμμάτων εγκατάστασης στον Κάδο", "Mover cachés, registros e instaladores a la Papelera", "Siirrä välimuistit, lokit ja asennusohjelmat Roskakoriin", "Gyorsítótárak, naplók és telepítők áthelyezése a Kukába", "Pindahkan cache, log, dan penginstal ke Tempat Sampah", "Alihkan cache, log dan pemasang ke Tong Sampah", "Flytt cacher, loggfiler og installasjonsprogrammer til Papirkurven", "Mover caches, registos e instaladores para o Lixo", "Mută cache-urile, jurnalele și instalatoarele în Coș", "Flytta cacher, loggar och installationsprogram till Papperskorgen", "ย้ายแคช บันทึก และไฟล์ติดตั้งไปที่ถังขยะ", "Переміщувати кеші, журнали та інсталятори в Кошик", "Chuyển bộ nhớ đệm, nhật ký và bộ cài vào Thùng rác"],
    "purchase.paidTier.uninstall": ["Деинсталирайте приложения със свързаните им файлове", "Odinstalovat aplikace s jejich souvisejícími soubory", "Afinstaller apps med deres relaterede filer", "Απεγκατάσταση εφαρμογών με τα σχετικά αρχεία τους", "Desinstalar aplicaciones con sus archivos relacionados", "Poista sovellukset liittyvine tiedostoineen", "Alkalmazások eltávolítása a kapcsolódó fájljaikkal", "Hapus aplikasi beserta file terkaitnya", "Nyahpasang apl bersama fail berkaitannya", "Avinstaller apper med tilknyttede filer", "Desinstalar aplicações com os respetivos ficheiros", "Dezinstalează aplicații împreună cu fișierele asociate", "Avinstallera appar med deras relaterade filer", "ถอนการติดตั้งแอปพร้อมไฟล์ที่เกี่ยวข้อง", "Видаляти програми разом із пов'язаними файлами", "Gỡ cài đặt ứng dụng cùng các tệp liên quan"],
    "purchase.paidTier.files": ["Почистете големи, стари и дублирани файлове", "Čistit velké, staré a duplicitní soubory", "Ryd store, gamle og dublerede filer", "Καθαρισμός μεγάλων, παλιών και διπλότυπων αρχείων", "Limpiar archivos grandes, antiguos y duplicados", "Siivoa suuret, vanhat ja kaksoiskappaletiedostot", "Nagy, régi és duplikált fájlok tisztítása", "Bersihkan file besar, lama, dan duplikat", "Bersihkan fail besar, lama dan pendua", "Rydd store, gamle og dupliserte filer", "Limpar ficheiros grandes, antigos e duplicados", "Curăță fișiere mari, vechi și duplicate", "Rensa stora, gamla och dubblerade filer", "ล้างไฟล์ขนาดใหญ่ ไฟล์เก่า และไฟล์ซ้ำ", "Очищати великі, старі й дублікатні файли", "Dọn tệp lớn, tệp cũ và tệp trùng"],
    "purchase.paidTier.report": ["Пълни отчети за почистване и експорт в PDF", "Úplné zprávy o čištění a export do PDF", "Fulde oprydningsrapporter og PDF-eksport", "Πλήρεις αναφορές καθαρισμού και εξαγωγή PDF", "Informes completos de limpieza y exportación en PDF", "Täydelliset siivousraportit ja PDF-vienti", "Teljes tisztítási jelentések és PDF-export", "Laporan pembersihan lengkap dan ekspor PDF", "Laporan pembersihan penuh dan eksport PDF", "Fullstendige oppryddingsrapporter og PDF-eksport", "Relatórios completos de limpeza e exportação em PDF", "Rapoarte complete de curățare și export PDF", "Fullständiga rensningsrapporter och PDF-export", "รายงานการทำความสะอาดแบบเต็มและการส่งออก PDF", "Повні звіти про очищення й експорт у PDF", "Báo cáo dọn dẹp đầy đủ và xuất PDF"],
    "purchase.activateLicense": ["Въведете лицензионен ключ", "Zadat licenční klíč", "Indtast licensnøgle", "Εισαγωγή κλειδιού άδειας", "Ingresar clave de licencia", "Syötä lisenssiavain", "Licenckulcs megadása", "Masukkan kunci lisensi", "Masukkan kunci lesen", "Skriv inn lisensnøkkel", "Introduzir chave de licença", "Introdu cheia de licență", "Ange licensnyckel", "ป้อนคีย์ลิขสิทธิ์", "Ввести ліцензійний ключ", "Nhập khóa giấy phép"],
    "purchase.restore": ["Възстановете покупката", "Obnovit nákup", "Gendan køb", "Επαναφορά αγοράς", "Restaurar compra", "Palauta osto", "Vásárlás visszaállítása", "Pulihkan pembelian", "Pulihkan pembelian", "Gjenopprett kjøp", "Restaurar compra", "Restaurează achiziția", "Återställ köp", "กู้คืนการซื้อ", "Відновити покупку", "Khôi phục giao dịch mua"],
    "purchase.restored": ["Покупката е възстановена. Почистването е отключено.", "Nákup obnoven. Čištění je odemčeno.", "Køb gendannet. Oprydning er låst op.", "Η αγορά επαναφέρθηκε. Ο καθαρισμός είναι ξεκλειδωμένος.", "Compra restaurada. La limpieza está desbloqueada.", "Osto palautettu. Siivous on avattu.", "A vásárlás visszaállítva. A tisztítás feloldva.", "Pembelian dipulihkan. Pembersihan telah dibuka.", "Pembelian dipulihkan. Pembersihan telah dibuka.", "Kjøp gjenopprettet. Opprydding er låst opp.", "Compra restaurada. A limpeza está desbloqueada.", "Achiziție restaurată. Curățarea este deblocată.", "Köpet återställt. Rensning är upplåst.", "กู้คืนการซื้อแล้ว ปลดล็อกการทำความสะอาดแล้ว", "Покупку відновлено. Очищення розблоковано.", "Đã khôi phục giao dịch mua. Đã mở khóa tính năng dọn dẹp."],
    "purchase.activated": ["Лицензът е активиран. Благодарим ви!", "Licence aktivována. Děkujeme!", "Licens aktiveret. Tak!", "Η άδεια ενεργοποιήθηκε. Ευχαριστούμε!", "Licencia activada. ¡Gracias!", "Lisenssi aktivoitu. Kiitos!", "Licenc aktiválva. Köszönjük!", "Lisensi diaktifkan. Terima kasih!", "Lesen diaktifkan. Terima kasih!", "Lisens aktivert. Takk!", "Licença ativada. Obrigado!", "Licență activată. Mulțumim!", "Licensen aktiverad. Tack!", "เปิดใช้งานลิขสิทธิ์แล้ว ขอบคุณ!", "Ліцензію активовано. Дякуємо!", "Đã kích hoạt giấy phép. Cảm ơn bạn!"],
    "purchase.failed": ["Не успяхме да завършим това. Опитайте отново.", "Nepodařilo se to dokončit. Zkuste to prosím znovu.", "Det kunne vi ikke fuldføre. Prøv igen.", "Δεν μπορέσαμε να ολοκληρώσουμε την ενέργεια. Δοκιμάστε ξανά.", "No se pudo completar. Inténtalo de nuevo.", "Emme voineet suorittaa sitä. Yritä uudelleen.", "Nem sikerült befejezni. Kérjük, próbálja újra.", "Kami tidak dapat menyelesaikannya. Silakan coba lagi.", "Kami tidak dapat menyelesaikannya. Sila cuba lagi.", "Vi kunne ikke fullføre det. Prøv igjen.", "Não foi possível concluir. Tente novamente.", "Nu am putut finaliza. Te rugăm să încerci din nou.", "Vi kunde inte slutföra det. Försök igen.", "เราไม่สามารถดำเนินการให้เสร็จได้ โปรดลองอีกครั้ง", "Не вдалося завершити. Спробуйте ще раз.", "Chúng tôi không thể hoàn tất. Vui lòng thử lại."],
    "purchase.networkUnavailable": ["Услугата за покупки не можа да бъде достигната. Лицензът ви остава използваем офлайн засега.", "Službu nákupu nešlo kontaktovat. Vaše licence zatím zůstává použitelná offline.", "Købstjenesten kunne ikke nås. Din licens kan bruges offline indtil videre.", "Δεν ήταν δυνατή η πρόσβαση στην υπηρεσία αγοράς. Η άδειά σας παραμένει προς το παρόν σε χρήση εκτός σύνδεσης.", "No se pudo contactar con el servicio de compra. Tu licencia sigue funcionando sin conexión por ahora.", "Ostopalveluun ei saatu yhteyttä. Lisenssisi toimii offline-tilassa toistaiseksi.", "A vásárlási szolgáltatás nem érhető el. A licence egyelőre offline is használható marad.", "Layanan pembelian tidak dapat dihubungi. Lisensi Anda tetap dapat digunakan secara offline untuk sementara.", "Perkhidmatan pembelian tidak dapat dihubungi. Lesen anda kekal boleh digunakan secara luar talian buat masa ini.", "Kjøpstjenesten kunne ikke nås. Lisensen din kan brukes offline foreløpig.", "Não foi possível contactar o serviço de compra. A sua licença continua a funcionar sem ligação por agora.", "Serviciul de achiziții nu a putut fi contactat. Licența rămâne utilizabilă offline deocamdată.", "Köptjänsten kunde inte nås. Din licens fungerar offline tills vidare.", "ไม่สามารถเชื่อมต่อบริการซื้อได้ ลิขสิทธิ์ของคุณยังใช้งานแบบออฟไลน์ได้ในตอนนี้", "Служба покупок недоступна. Ваша ліцензія поки працює офлайн.", "Không thể kết nối dịch vụ mua hàng. Giấy phép của bạn vẫn dùng được ngoại tuyến trong lúc này."],
    "purchase.licenseRequired": ["Отключете Sift, за да почиствате", "Pro čištění odemkněte Sift", "Lås Sift op for at rydde", "Ξεκλειδώστε το Sift για καθαρισμό", "Desbloquea Sift para limpiar", "Avaa Sift käyttöön siivotaksesi", "A tisztításhoz oldja fel a Siftet", "Buka Sift untuk membersihkan", "Buka Sift untuk membersihkan", "Lås opp Sift for å rydde", "Desbloqueie o Sift para limpar", "Deblochează Sift pentru a curăța", "Lås upp Sift för att rensa", "ปลดล็อก Sift เพื่อทำความสะอาด", "Розблокуйте Sift для очищення", "Mở khóa Sift để dọn dẹp"],
    "purchase.licenseRequiredDetail": ["Сканирането, анализът и прегледите остават безплатни. Почистването и деинсталирането изискват еднократна покупка.", "Skenování, analýza a náhledy zůstávají zdarma. Čištění a odinstalace vyžadují jednorázový nákup.", "Scanning, analyse og forhåndsvisning er gratis. Oprydning og afinstallation kræver engangskøbet.", "Η σάρωση, η ανάλυση και οι προεπισκοπήσεις παραμένουν δωρεάν. Ο καθαρισμός και η απεγκατάσταση απαιτούν την αγορά μία φορά.", "Analizar, medir y previsualizar sigue siendo gratis. Limpiar y desinstalar requiere la compra única.", "Skannaus, analyysi ja esikatselut ovat ilmaisia. Siivous ja asennuksen poisto vaativat kertaoston.", "A vizsgálat, az elemzés és az előnézetek ingyenesek maradnak. A tisztításhoz és az eltávolításhoz egyszeri vásárlás kell.", "Pemindaian, analisis, dan pratinjau tetap gratis. Pembersihan dan penghapusan memerlukan pembelian sekali bayar.", "Pengimbasan, analisis dan pratonton kekal percuma. Pembersihan dan penyahpasangan memerlukan pembelian sekali bayar.", "Skanning, analyse og forhåndsvisning forblir gratis. Opprydding og avinstallering krever engangskjøpet.", "A verificação, a análise e as pré-visualizações continuam gratuitas. Limpar e desinstalar requerem a compra única.", "Scanarea, analiza și previzualizările rămân gratuite. Curățarea și dezinstalarea necesită achiziția unică.", "Skanning, analys och förhandsvisning är gratis. Rensning och avinstallation kräver engångsköpet.", "การสแกน การวิเคราะห์ และการแสดงตัวอย่างยังฟรี การทำความสะอาดและการถอนการติดตั้งต้องซื้อครั้งเดียว", "Сканування, аналіз і перегляд залишаються безкоштовними. Очищення й видалення потребують одноразової покупки.", "Quét, phân tích và xem trước vẫn miễn phí. Dọn dẹp và gỡ cài đặt cần mua một lần."],
    "purchase.offlineGrace": ["Офлайн период: остават %d дни", "Období offline: zbývá %d dní", "Offline-frist: %d dage tilbage", "Περίοδος χάριτος εκτός σύνδεσης: απομένουν %d ημέρες", "Período sin conexión: quedan %d días", "Offline-ajanjakso: %d päivää jäljellä", "Offline türelmi idő: %d nap van hátra", "Masa tenggang offline: %d hari lagi", "Tempoh tangguh luar talian: %d hari lagi", "Offline-frist: %d dager igjen", "Período de tolerância sem ligação: faltam %d dias", "Zile de grație offline rămase: %d", "Offlineperiod: %d dagar kvar", "ช่วงผ่อนผันออฟไลน์: เหลือ %d วัน", "Офлайн-період: залишилося %d днів", "Thời gian gia hạn ngoại tuyến: còn %d ngày"],
    "purchase.status.purchased": ["Закупено", "Zakoupeno", "Købt", "Αγορασμένο", "Comprado", "Ostettu", "Megvásárolva", "Dibeli", "Dibeli", "Kjøpt", "Comprado", "Achiziționat", "Köpt", "ซื้อแล้ว", "Придбано", "Đã mua"],
    "purchase.status.free": ["Безплатна версия", "Bezplatná verze", "Gratisversion", "Δωρεάν έκδοση", "Versión gratuita", "Ilmainen versio", "Ingyenes verzió", "Versi gratis", "Versi percuma", "Gratisversjon", "Versão gratuita", "Versiune gratuită", "Gratisversion", "เวอร์ชันฟรี", "Безкоштовна версія", "Bản miễn phí"],
    "nav.account": ["Акаунт", "Účet", "Konto", "Λογαριασμός", "Cuenta", "Tili", "Fiók", "Akun", "Akaun", "Konto", "Conta", "Cont", "Konto", "บัญชี", "Акаунт", "Tài khoản"],
    "account.activatedAt": ["Дата на активиране", "Datum aktivace", "Aktiveret den", "Ημερομηνία ενεργοποίησης", "Fecha de activación", "Aktivoitu", "Aktiválás dátuma", "Tanggal aktivasi", "Tarikh pengaktifan", "Aktivert den", "Data de ativação", "Data activării", "Aktiverad den", "วันที่เปิดใช้งาน", "Дата активації", "Ngày kích hoạt"],
    "account.licenseKey": ["Лицензионен ключ", "Licenční klíč", "Licensnøgle", "Κλειδί άδειας", "Clave de licencia", "Lisenssiavain", "Licenckulcs", "Kunci lisensi", "Kunci lesen", "Lisensnøkkel", "Chave de licença", "Cheie de licență", "Licensnyckel", "คีย์ลิขสิทธิ์", "Ліцензійний ключ", "Khóa giấy phép"],
    "report.title": ["Отчет за почистването", "Zpráva o čištění", "Oprydningsrapport", "Αναφορά καθαρισμού", "Informe de limpieza", "Siivousraportti", "Tisztítási jelentés", "Laporan pembersihan", "Laporan pembersihan", "Oppryddingsrapport", "Relatório de limpeza", "Raport de curățare", "Rensningsrapport", "รายงานการทำความสะอาด", "Звіт про очищення", "Báo cáo dọn dẹp"],
    "report.generatedAt": ["Създаден на %@", "Vytvořeno %@", "Oprettet %@", "Δημιουργήθηκε %@", "Generado el %@", "Luotu %@", "Létrehozva: %@", "Dibuat %@", "Dijana %@", "Generert %@", "Gerado em %@", "Generat %@", "Skapad %@", "สร้างเมื่อ %@", "Створено %@", "Được tạo %@"],
    "report.appVersion": ["Sift %@ на macOS %@", "Sift %@ na macOS %@", "Sift %@ på macOS %@", "Sift %@ σε macOS %@", "Sift %@ en macOS %@", "Sift %@, macOS %@", "Sift %@ – macOS %@", "Sift %@ di macOS %@", "Sift %@ pada macOS %@", "Sift %@ på macOS %@", "Sift %@ no macOS %@", "Sift %@ pe macOS %@", "Sift %@ på macOS %@", "Sift %@ บน macOS %@", "Sift %@ на macOS %@", "Sift %@ trên macOS %@"],
    "report.scope": ["Какво е сканирано", "Co bylo skenováno", "Det blev scannet", "Τι σαρώθηκε", "Qué se analizó", "Mitä skannattiin", "Mit vizsgáltunk", "Apa yang dipindai", "Apa yang diimbas", "Det som ble skannet", "O que foi verificado", "Ce a fost scanat", "Det som skannades", "สิ่งที่สแกน", "Що скановано", "Những gì đã quét"],
    "report.scopeDetail": ["%d места, прегледани %d файла", "Místa: %d, prozkoumané soubory: %d", "%d placeringer, %d filer undersøgt", "%d τοποθεσίες, %d αρχεία εξετάστηκαν", "%d ubicaciones, %d archivos examinados", "%d sijaintia, %d tiedostoa tarkistettu", "%d hely, %d fájl átvizsgálva", "%d lokasi, %d file diperiksa", "%d lokasi, %d fail diperiksa", "%d steder, %d filer undersøkt", "%d locais, %d ficheiros examinados", "Locații: %d, fișiere examinate: %d", "%d platser, %d filer granskade", "%d ตำแหน่ง ตรวจสอบ %d ไฟล์", "%d місць, перевірено %d файлів", "%d vị trí, %d tệp đã kiểm tra"],
    "report.categories": ["Обработени категории", "Zpracované kategorie", "Håndterede kategorier", "Κατηγορίες που χειρίστηκαν", "Categorías tratadas", "Käsitellyt kategoriat", "Kezelt kategóriák", "Kategori yang ditangani", "Kategori yang dikendalikan", "Håndterte kategorier", "Categorias tratadas", "Categorii tratate", "Hanterade kategorier", "หมวดหมู่ที่จัดการ", "Оброблені категорії", "Danh mục đã xử lý"],
    "report.status": ["Състояние", "Stav", "Status", "Κατάσταση", "Estado", "Tila", "Állapot", "Status", "Status", "Status", "Estado", "Stare", "Status", "สถานะ", "Статус", "Trạng thái"],
    "report.status.moved": ["Преместено в Кошчето", "Přesunuto do Koše", "Flyttet til Papirkurven", "Μετακινήθηκε στον Κάδο", "Movido a la Papelera", "Siirretty Roskakoriin", "Kukába helyezve", "Dipindahkan ke Tempat Sampah", "Dialihkan ke Tong Sampah", "Flyttet til Papirkurven", "Movido para o Lixo", "Mutat în Coș", "Flyttade till Papperskorgen", "ย้ายไปที่ถังขยะแล้ว", "Переміщено в Кошик", "Đã chuyển vào Thùng rác"],
    "report.status.skipped": ["Пропуснато", "Přeskočeno", "Sprunget over", "Παραλείφθηκε", "Omitido", "Ohitettu", "Kihagyva", "Dilewati", "Dilangkau", "Hoppet over", "Ignorado", "Ignorat", "Överhoppade", "ข้ามไป", "Пропущено", "Đã bỏ qua"],
    "report.status.failed": ["Неуспешно", "Nezdařilo se", "Mislykkedes", "Απέτυχε", "Sin completar", "Epäonnistui", "Sikertelen", "Gagal", "Gagal", "Mislyktes", "Não concluído", "Eșuat", "Misslyckades", "ล้มเหลว", "Не виконано", "Thất bại"],
    "report.moved": ["Преместено в Кошчето", "Přesunuto do Koše", "Flyttet til Papirkurven", "Μετακινήθηκε στον Κάδο", "Movido a la Papelera", "Siirretty Roskakoriin", "Kukába helyezve", "Dipindahkan ke Tempat Sampah", "Dialihkan ke Tong Sampah", "Flyttet til Papirkurven", "Movido para o Lixo", "Mutat în Coș", "Flyttade till Papperskorgen", "ย้ายไปที่ถังขยะแล้ว", "Переміщено в Кошик", "Đã chuyển vào Thùng rác"],
    "report.movedDetail": ["%d елемента, %@", "Položky: %d, %@", "%d elementer, %@", "%d στοιχεία, %@", "%d elementos, %@", "%d kohdetta, %@", "%d elem, %@", "%d item, %@", "%d item, %@", "%d elementer, %@", "%d itens, %@", "Elemente: %d, %@", "%d objekt, %@", "%d รายการ %@", "%d елементів, %@", "%d mục, %@"],
    "report.released": ["Освободено място", "Uvolněné místo", "Frigivet plads", "Χώρος που ελευθερώθηκε", "Espacio liberado", "Vapautettu tila", "Felszabadított terület", "Ruang yang dibebaskan", "Ruang yang dilepaskan", "Frigjort plass", "Espaço libertado", "Spațiu eliberat", "Frigjort utrymme", "พื้นที่ที่ปลดปล่อย", "Звільнено місця", "Dung lượng đã giải phóng"],
    "report.skipped": ["Пропуснати", "Přeskočeno", "Sprunget over", "Παραλείφθηκαν", "Omitidos", "Ohitettu", "Kihagyva", "Dilewati", "Dilangkau", "Hoppet over", "Ignorados", "Ignorat", "Överhoppade", "ข้ามไป", "Пропущено", "Đã bỏ qua"],
    "report.skippedDetail": ["Пропуснати %d елемента. Показани са първите 20.", "Přeskočeno položek: %d. Zobrazeno prvních 20.", "Sprang %d elementer over. Viser de første 20.", "Παραλείφθηκαν %d στοιχεία. Εμφανίζονται τα πρώτα 20.", "Se omitieron %d elementos. Se muestran los primeros 20.", "%d kohdetta ohitettiin. Näytetään ensimmäiset 20.", "%d elem kihagyva. Az első 20 látható.", "%d item dilewati. Menampilkan 20 item pertama.", "%d item dilangkau. Memaparkan 20 item pertama.", "Hoppet over %d elementer. Viser de første 20.", "Foram ignorados %d itens. A mostrar os primeiros 20.", "Elemente ignorate: %d. Se afișează primele 20.", "Hoppade över %d objekt. Visar de första 20.", "ข้ามไป %d รายการ แสดง 20 รายการแรก", "Пропущено елементів: %d. Показано перші 20.", "Đã bỏ qua %d mục. Đang hiển thị 20 mục đầu tiên."],
    "report.failed": ["Не е завършено", "Nedokončeno", "Ikke fuldført", "Δεν ολοκληρώθηκε", "Sin completar", "Ei valmis", "Nem fejeződött be", "Tidak selesai", "Tidak selesai", "Ikke fullført", "Não concluídos", "Nefinalizat", "Inte slutfört", "ไม่เสร็จสมบูรณ์", "Не завершено", "Chưa hoàn tất"],
    "report.failedDetail": ["%d елемента, вижте подробностите по-долу", "Položky: %d, podrobnosti níže", "%d elementer, se detaljer nedenfor", "%d στοιχεία, δείτε τις λεπτομέρειες παρακάτω", "%d elementos, consulta los detalles abajo", "%d kohdetta, katso tiedot alta", "%d elem, a részleteket lásd alább", "%d item, lihat detail di bawah", "%d item, lihat butiran di bawah", "%d elementer, se detaljer nedenfor", "%d itens, consulte os detalhes abaixo", "Elemente: %d, vezi detaliile mai jos", "%d objekt, se detaljer nedan", "%d รายการ ดูรายละเอียดด้านล่าง", "%d елементів, деталі нижче", "%d mục, xem chi tiết bên dưới"],
    "report.privacyNote": ["Този отчет изброява само категории и размери. Не съдържа имена на файлове, пътища или съдържание.", "Tato zpráva uvádí jen kategorie a velikosti. Neobsahuje názvy souborů, cesty ani obsah souborů.", "Denne rapport viser kun kategorier og størrelser. Den indeholder ingen filnavne, stier eller filindhold.", "Αυτή η αναφορά απαριθμεί μόνο κατηγορίες και μεγέθη. Δεν περιέχει ονόματα αρχείων, διαδρομές ή περιεχόμενα αρχείων.", "Este informe solo indica categorías y tamaños. No contiene nombres de archivos, rutas ni contenidos.", "Tämä raportti luettelee vain kategoriat ja koot. Se ei sisällä tiedostonimiä, polkuja tai tiedostojen sisältöä.", "Ez a jelentés csak kategóriákat és méreteket sorol fel. Nem tartalmaz fájlneveket, elérési utakat vagy fájltartalmat.", "Laporan ini hanya mencantumkan kategori dan ukuran. Tidak berisi nama file, jalur, atau konten file.", "Laporan ini menyenaraikan kategori dan saiz sahaja. Ia tidak mengandungi nama fail, laluan atau kandungan fail.", "Denne rapporten viser bare kategorier og størrelser. Den inneholder ingen filnavn, stier eller filinnhold.", "Este relatório lista apenas categorias e tamanhos. Não contém nomes de ficheiros, caminhos nem conteúdos.", "Acest raport listează doar categorii și dimensiuni. Nu conține nume de fișiere, căi sau conținutul fișierelor.", "Den här rapporten visar bara kategorier och storlekar. Den innehåller inga filnamn, sökvägar eller filinnehåll.", "รายงานนี้แสดงเฉพาะหมวดหมู่และขนาด ไม่มีชื่อไฟล์ เส้นทาง หรือเนื้อหาไฟล์", "Цей звіт містить лише категорії та розміри. У ньому немає назв файлів, шляхів чи вмісту.", "Báo cáo này chỉ liệt kê danh mục và kích thước. Không chứa tên tệp, đường dẫn hay nội dung tệp."],
    "report.exportFailed": ["Отчетът не можа да бъде запазен. Все още се пази локално, така че можете да опитате отново.", "Zprávu nešlo uložit. Zůstává uložena lokálně, takže to můžete zkusit znovu.", "Rapporten kunne ikke gemmes. Den bevares stadig lokalt, så du kan prøve igen.", "Η αναφορά δεν ήταν δυνατό να αποθηκευτεί. Διατηρείται τοπικά, ώστε να μπορείτε να δοκιμάσετε ξανά.", "No se pudo guardar el informe. La copia local sigue disponible para volver a intentarlo.", "Raporttia ei voitu tallentaa. Se säilytetään silti paikallisesti, joten voit yrittää uudelleen.", "A jelentést nem sikerült menteni. Helyben továbbra is megvan, így újra próbálkozhat.", "Laporan tidak dapat disimpan. Laporan tetap tersimpan secara lokal, jadi Anda dapat mencoba lagi.", "Laporan tidak dapat disimpan. Ia masih disimpan secara setempat, jadi anda boleh mencuba lagi.", "Rapporten kunne ikke lagres. Den beholdes fortsatt lokalt, så du kan prøve igjen.", "O relatório não pôde ser guardado. Continua disponível localmente, pelo que pode tentar novamente.", "Raportul nu a putut fi salvat. Este încă păstrat local, așa că poți încerca din nou.", "Rapporten kunde inte sparas. Den finns fortfarande kvar lokalt, så du kan försöka igen.", "ไม่สามารถบันทึกรายงานได้ แต่รายงานยังถูกเก็บไว้ในเครื่อง ดังนั้นคุณสามารถลองอีกครั้งได้", "Не вдалося зберегти звіт. Його локальну копію збережено, тож можна спробувати ще раз.", "Không thể lưu báo cáo. Báo cáo vẫn được giữ trên máy nên bạn có thể thử lại."],
    "permission.fullDiskAccess": ["Пълен достъп до диска", "Úplný přístup k disku", "Fuld diskadgang", "Πλήρης πρόσβαση στον δίσκο", "Acceso total al disco", "Täysi levynkäyttöoikeus", "Teljes lemezhozzáférés", "Akses Disk Penuh", "Akses Cakera Penuh", "Full disktilgang", "Acesso Total ao Disco", "Acces complet la disc", "Fullskivåtkomst", "การเข้าถึงดิสก์ทั้งหมด", "Повний доступ до диска", "Quyền truy cập Toàn bộ Đĩa"],
    "permission.fullDiskAccessDetail": ["Sift сканира кешове и журнали и без него. С Пълен достъп до диска той може да чете и системни журнали и папки за поддръжка на приложения.", "Sift skenuje mezipaměti a protokoly i bez něj. S Úplným přístupem k disku může číst i systémové protokoly a složky podpory aplikací.", "Sift scanner caches og logfiler uden den. Med fuld diskadgang kan den også læse systemlogfiler og app-supportmapper.", "Το Sift σαρώνει cache και αρχεία καταγραφής και χωρίς αυτή. Με την Πλήρη πρόσβαση στον δίσκο μπορεί να διαβάζει και αρχεία καταγραφής συστήματος και φακέλους υποστήριξης εφαρμογών.", "Sift analiza cachés y registros sin este acceso. Al concederlo, también puede leer registros del sistema y carpetas de soporte de aplicaciones.", "Sift skannaa välimuistit ja lokit ilman sitä. Täysi levynkäyttöoikeus antaa sen lukea myös järjestelmän lokit ja sovellusten tukikansiot.", "A Sift e nélkül is vizsgálja a gyorsítótárakat és naplókat. A Teljes lemezhozzáférés megadásával a rendszernaplókat és az alkalmazástámogató mappákat is be tudja olvasni.", "Sift memindai cache dan log tanpa ini. Memberikan Akses Disk Penuh memungkinkannya juga membaca log sistem dan folder dukungan aplikasi.", "Sift mengimbas cache dan log tanpanya. Memberikan Akses Cakera Penuh membolehkannya turut membaca log sistem dan folder sokongan apl.", "Sift skanner cacher og loggfiler uten den. Med full disktilgang kan den også lese systemloggfiler og appstøttemapper.", "O Sift verifica caches e registos sem este acesso. Ao conceder Acesso Total ao Disco, também pode ler registos do sistema e pastas de suporte das aplicações.", "Sift scanează cache-urile și jurnalele și fără el. Acordarea Accesului complet la disc îi permite să citească și jurnalele de sistem și folderele de suport ale aplicațiilor.", "Sift skannar cacher och loggar utan den. Med fullskivåtkomst kan den även läsa systemloggar och appsupportmappar.", "Sift สแกนแคชและบันทึกได้โดยไม่ต้องใช้สิทธิ์นี้ การอนุญาตการเข้าถึงดิสก์ทั้งหมดทำให้อ่านบันทึกของระบบและโฟลเดอร์สนับสนุนแอปได้ด้วย", "Sift сканує кеші й журнали й без нього. З Повним доступом до диска він також читає системні журнали й папки підтримки програм.", "Sift quét bộ nhớ đệm và nhật ký mà không cần quyền này. Cấp Quyền truy cập Toàn bộ Đĩa cho phép đọc cả nhật ký hệ thống và thư mục hỗ trợ ứng dụng."],
    "permission.partialAccess": ["Някои места не можаха да бъдат прочетени", "Některá místa nebylo možné načíst", "Nogle placeringer kunne ikke læses", "Ορισμένες τοποθεσίες δεν ήταν δυνατό να διαβαστούν", "No se pudieron leer algunas ubicaciones", "Joitakin sijainteja ei voitu lukea", "Néhány helyet nem sikerült beolvasni", "Beberapa lokasi tidak dapat dibaca", "Sesetengah lokasi tidak dapat dibaca", "Noen steder kunne ikke leses", "Não foi possível ler alguns locais", "Unele locații nu au putut fi citite", "Vissa platser kunde inte läsas", "อ่านบางตำแหน่งไม่ได้", "Деякі місця не вдалося прочитати", "Không đọc được một số vị trí"],
    "permission.openSettings": ["Отворете Системни настройки", "Otevřít Nastavení systému", "Åbn Systemindstillinger", "Άνοιγμα Ρυθμίσεων συστήματος", "Abrir Ajustes del Sistema", "Avaa Järjestelmäasetukset", "Rendszerbeállítások megnyitása", "Buka Pengaturan Sistem", "Buka Tetapan Sistem", "Åpne Systeminnstillinger", "Abrir Definições do Sistema", "Deschide Configurările sistemului", "Öppna Systeminställningar", "เปิดการตั้งค่าระบบ", "Відкрити Системні налаштування", "Mở Cài đặt Hệ thống"],
    "permission.grantLater": ["Продължете без него", "Pokračovat bez něj", "Fortsæt uden", "Συνέχεια χωρίς αυτή", "Continuar sin acceso", "Jatka ilman", "Folytatás nélküle", "Lanjutkan tanpa ini", "Teruskan tanpanya", "Fortsett uten", "Continuar sem acesso", "Continuă fără el", "Fortsätt utan", "ดำเนินการต่อโดยไม่ให้สิทธิ์", "Продовжити без нього", "Tiếp tục không cấp quyền"],
    "settings.diagnostics.scannerCore": ["Ядро на сканирането", "Jádro skeneru", "Scanningskerne", "Πυρήνας σάρωσης", "Núcleo de análisis", "Skannausydin", "Szkenner-mag", "Inti pemindai", "Teras pengimbas", "Skannermotor", "Núcleo de verificação", "Nucleul scanerului", "Skanningskärna", "แกนสแกน", "Ядро сканування", "Lõi quét"],
    "settings.diagnostics.version": ["Версия", "Verze", "Version", "Έκδοση", "Versión", "Versio", "Verzió", "Versi", "Versi", "Versjon", "Versão", "Versiune", "Version", "เวอร์ชัน", "Версія", "Phiên bản"],
    "settings.diagnostics.macOS": ["macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS", "macOS"],
    "common.done": ["Готово", "Hotovo", "Færdig", "Τέλος", "Hecho", "Valmis", "Kész", "Selesai", "Selesai", "Ferdig", "Concluído", "Gata", "Klart", "เสร็จสิ้น", "Готово", "Xong"],
    "common.close": ["Затворете", "Zavřít", "Luk", "Κλείσιμο", "Cerrar", "Sulje", "Bezárás", "Tutup", "Tutup", "Lukk", "Fechar", "Închide", "Stäng", "ปิด", "Закрити", "Đóng"],
    "common.remove": ["Премахнете", "Odstranit", "Fjern", "Αφαίρεση", "Eliminar", "Poista", "Eltávolítás", "Hapus", "Buang", "Fjern", "Eliminar", "Elimină", "Ta bort", "นำออก", "Видалити", "Xóa"],
    "common.unknownError": ["Това не се получи. Опитайте отново.", "To se nepovedlo. Zkuste to znovu.", "Det virkede ikke. Prøv igen.", "Δεν λειτούργησε. Δοκιμάστε ξανά.", "No funcionó. Inténtalo de nuevo.", "Se ei onnistunut. Yritä uudelleen.", "Nem sikerült. Próbálja újra.", "Itu tidak berhasil. Coba lagi.", "Tidak berjaya. Cuba lagi.", "Det gikk ikke. Prøv igjen.", "Não funcionou. Tente novamente.", "Nu a funcționat. Încearcă din nou.", "Det gick inte. Försök igen.", "ไม่สำเร็จ ลองอีกครั้ง", "Не вийшло. Спробуйте ще раз.", "Không thành công. Hãy thử lại."],
    "common.fileCount": ["%d файла", "%d souborů", "%d filer", "%d αρχεία", "%d archivos", "%d tiedostoa", "%d fájl", "%d file", "%d fail", "%d filer", "%d ficheiros", "Fișiere: %d", "%d filer", "%d ไฟล์", "%d файлів", "%d tệp"],
    "common.itemCount": ["%d елемента", "%d položek", "%d elementer", "%d στοιχεία", "%d elementos", "%d kohdetta", "%d elem", "%d item", "%d item", "%d elementer", "%d itens", "Elemente: %d", "%d objekt", "%d รายการ", "%d елементів", "%d mục"],
    "common.notAvailable": ["Не е налично", "Není k dispozici", "Ikke tilgængelig", "Μη διαθέσιμο", "No disponible", "Ei saatavilla", "Nem érhető el", "Tidak tersedia", "Tidak tersedia", "Ikke tilgjengelig", "Não disponível", "Indisponibil", "Inte tillgängligt", "ไม่พร้อมใช้งาน", "Недоступно", "Không khả dụng"],
    "common.loadMore": ["Заредете още", "Načíst další", "Indlæs mere", "Φόρτωση περισσότερων", "Cargar más", "Lataa lisää", "Továbbiak betöltése", "Muat lebih banyak", "Muatkan lagi", "Last inn flere", "Carregar mais", "Încarcă mai multe", "Läs in fler", "โหลดเพิ่มเติม", "Завантажити ще", "Tải thêm"],
    "common.retry": ["Опитайте отново", "Zkusit znovu", "Prøv igen", "Δοκιμάστε ξανά", "Reintentar", "Yritä uudelleen", "Újrapróbálás", "Coba lagi", "Cuba lagi", "Prøv igjen", "Tentar novamente", "Încearcă din nou", "Försök igen", "ลองอีกครั้ง", "Спробувати ще раз", "Thử lại"],
    "common.of": ["%@ от %@", "%@ z %@", "%@ af %@", "%@ από %@", "%@ de %@", "%@ / %@", "%@ / %@", "%@ dari %@", "%@ daripada %@", "%@ av %@", "%@ de %@", "%@ din %@", "%@ av %@", "%@ จาก %@", "%@ із %@", "%@ trên %@"],
    "common.size": ["Размер", "Velikost", "Størrelse", "Μέγεθος", "Tamaño", "Koko", "Méret", "Ukuran", "Saiz", "Størrelse", "Tamanho", "Dimensiune", "Storlek", "ขนาด", "Розмір", "Kích thước"],
    "common.risk": ["Риск", "Riziko", "Risiko", "Κίνδυνος", "Riesgo", "Riski", "Kockázat", "Risiko", "Risiko", "Risiko", "Risco", "Risc", "Risk", "ความเสี่ยง", "Ризик", "Rủi ro"],
    "common.quitApp": ["Затворете приложението", "Ukončit aplikaci", "Afslut app", "Κλείσιμο εφαρμογής", "Cerrar aplicación", "Lopeta sovellus", "Alkalmazás bezárása", "Keluar dari aplikasi", "Keluar dari apl", "Avslutt app", "Encerrar aplicação", "Închide aplicația", "Avsluta app", "ปิดแอป", "Закрити програму", "Thoát ứng dụng"],
    "common.loading": ["Зареждане…", "Načítání…", "Indlæser…", "Φόρτωση…", "Cargando…", "Ladataan…", "Betöltés…", "Memuat…", "Memuatkan…", "Laster inn…", "A carregar…", "Se încarcă…", "Läser in…", "กำลังโหลด…", "Завантаження…", "Đang tải…"],
    "common.sortBy": ["Сортиране по", "Seřadit podle", "Sortér efter", "Ταξινόμηση κατά", "Ordenar por", "Lajittele", "Rendezés", "Urutkan menurut", "Isih mengikut", "Sorter etter", "Ordenar por", "Sortează după", "Sortera efter", "เรียงตาม", "Сортувати за", "Sắp xếp theo"],
    "nav.scan": ["Сканиране", "Skenovat", "Scan", "Σάρωση", "Analizar", "Skannaa", "Vizsgálat", "Pindai", "Imbas", "Skann", "Verificação", "Scanare", "Skanning", "สแกน", "Сканування", "Quét"],
    "nav.apps": ["Приложения", "Aplikace", "Apps", "Εφαρμογές", "Aplicaciones", "Sovellukset", "Alkalmazások", "Aplikasi", "Apl", "Apper", "Aplicações", "Aplicații", "Appar", "แอป", "Програми", "Ứng dụng"],
    "overview.scanScope": ["Какво обхваща сканирането", "Co skenování zahrnuje", "Det dækker en scanning", "Τι καλύπτει μια σάρωση", "Qué abarca un análisis", "Mitä skannaus kattaa", "Mit fed le a vizsgálat", "Apa yang dicakup pemindaian", "Apa yang diliputi imbasan", "Det en skanning dekker", "O que abrange uma verificação", "Ce acoperă o scanare", "Vad en skanning omfattar", "สิ่งที่การสแกนครอบคลุม", "Що охоплює сканування", "Phạm vi quét"],
    "overview.status": ["%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@", "%@"],
    "overview.reclaimable.title": ["Безопасно за освобождаване", "Bezpečné k uvolnění", "Sikkert at frigive", "Ασφαλής ελευθέρωση χώρου", "Seguro para liberar", "Turvallista vapauttaa", "Biztonságosan felszabadítható", "Aman untuk dibebaskan", "Selamat untuk dilepaskan", "Trygt å frigjøre", "Seguro para libertar", "Sigur de eliberat", "Säkert att frigöra", "ปลดปล่อยได้อย่างปลอดภัย", "Безпечно звільнити", "Có thể giải phóng an toàn"],
    "overview.reclaimable.breakdown": ["%@ е безопасно, %@ изисква вашето потвърждение", "%@ je bezpečné, %@ vyžaduje vaše potvrzení", "%@ er sikkert, %@ kræver din bekræftelse", "%@ είναι ασφαλή, %@ χρειάζονται την επιβεβαίωσή σας", "%@ es seguro, %@ requiere tu confirmación", "%@ on turvallista, %@ vaatii vahvistuksesi", "%@ biztonságos, %@ az Ön megerősítését igényli", "%@ aman, %@ memerlukan konfirmasi Anda", "%@ selamat, %@ memerlukan pengesahan anda", "%@ er trygt, %@ trenger bekreftelsen din", "%@ é seguro, %@ requer a sua confirmação", "%@ este sigur, %@ necesită confirmarea ta", "%@ är säkert, %@ behöver din bekräftelse", "%@ ปลอดภัย %@ ต้องได้รับการยืนยันจากคุณ", "%@ безпечно, %@ потребує вашого підтвердження", "%@ an toàn, %@ cần bạn xác nhận"],
    "overview.reclaimable.meta": ["%d категории, %d елемента", "Kategorie: %d, položky: %d", "%d kategorier, %d elementer", "%d κατηγορίες, %d στοιχεία", "%d categorías, %d elementos", "%d kategoriaa, %d kohdetta", "%d kategória, %d elem", "%d kategori, %d item", "%d kategori, %d item", "%d kategorier, %d elementer", "%d categorias, %d itens", "%d categorii, %d elemente", "%d kategorier, %d objekt", "%d หมวดหมู่, %d รายการ", "%d категорій, %d елементів", "%d danh mục, %d mục"],
    "overview.ready": ["Готово за сканиране", "Připraveno ke skenování", "Klar til scanning", "Έτοιμο για σάρωση", "Listo para analizar", "Valmis skannaamaan", "Vizsgálatra kész", "Siap dipindai", "Sedia untuk diimbas", "Klar til skanning", "Pronto para verificar", "Gata de scanare", "Redo att skanna", "พร้อมสแกน", "Готово до сканування", "Sẵn sàng quét"],
    "overview.noResults": ["Стартирайте сканиране, за да видите какво може да се освободи безопасно.", "Spusťte skenování a uvidíte, co lze bezpečně uvolnit.", "Kør en scanning for at se, hvad der kan frigives sikkert.", "Εκτελέστε μια σάρωση για να δείτε τι μπορεί να ελευθερωθεί με ασφάλεια.", "Ejecuta un análisis para ver qué se puede liberar de forma segura.", "Suorita skannaus, niin näet, mitä voidaan vapauttaa turvallisesti.", "Indítson vizsgálatot, hogy lássa, mi szabadítható fel biztonságosan.", "Jalankan pemindaian untuk melihat apa yang dapat dibebaskan dengan aman.", "Jalankan imbasan untuk melihat apa yang boleh dilepaskan dengan selamat.", "Kjør en skanning for å se hva som trygt kan frigjøres.", "Execute uma verificação para ver o que pode ser libertado em segurança.", "Rulează o scanare pentru a vedea ce poate fi eliberat în siguranță.", "Kör en skanning för att se vad som säkert kan frigöras.", "รันการสแกนเพื่อดูว่าปลดปล่อยอะไรได้อย่างปลอดภัย", "Запустіть сканування, щоб побачити, що можна безпечно звільнити.", "Chạy quét để xem có thể giải phóng an toàn những gì."],
    "overview.viewProgress": ["Вижте напредъка на сканирането", "Zobrazit průběh skenování", "Se scanningsfremdrift", "Προβολή προόδου σάρωσης", "Ver el progreso del análisis", "Näytä skannauksen edistyminen", "Vizsgálat folyamatának megtekintése", "Lihat kemajuan pemindaian", "Lihat kemajuan imbasan", "Se skanningsfremdrift", "Ver progresso da verificação", "Vezi progresul scanării", "Visa skanningsförlopp", "ดูความคืบหน้าการสแกน", "Переглянути поступ сканування", "Xem tiến trình quét"],
    "overview.noCleanup": ["Все още няма почистване", "Zatím žádné čištění", "Ingen oprydning endnu", "Δεν έχει γίνει καθαρισμός ακόμη", "Aún no hay limpiezas", "Ei vielä siivousta", "Még nincs tisztítás", "Belum ada pembersihan", "Belum ada pembersihan", "Ingen opprydding ennå", "Ainda não há limpezas", "Încă nicio curățare", "Ingen rensning än", "ยังไม่มีการทำความสะอาด", "Очищень ще не було", "Chưa dọn dẹp lần nào"],
    "overview.cleanupHistoryHint": ["Историята на почистванията ще се появи тук.", "Zde se zobrazí historie čištění.", "Oprydningshistorik vises her.", "Το ιστορικό καθαρισμών εμφανίζεται εδώ.", "El historial de limpiezas aparecerá aquí.", "Siivoushistoria näkyy täällä.", "A tisztítási előzmények itt jelennek meg.", "Riwayat pembersihan muncul di sini.", "Sejarah pembersihan muncul di sini.", "Oppryddingshistorikk vises her.", "O histórico de limpezas aparece aqui.", "Istoricul curățărilor apare aici.", "Rensningshistorik visas här.", "ประวัติการทำความสะอาดจะแสดงที่นี่", "Історія очищень з'явиться тут.", "Lịch sử dọn dẹp xuất hiện ở đây."],
    "overview.viewResults": ["Вижте резултатите от сканирането", "Zobrazit výsledky skenování", "Se scanningsresultater", "Προβολή αποτελεσμάτων σάρωσης", "Ver resultados del análisis", "Näytä skannaustulokset", "Vizsgálati eredmények megtekintése", "Lihat hasil pemindaian", "Lihat hasil imbasan", "Se skanneresultater", "Ver resultados da verificação", "Vezi rezultatele scanării", "Visa skanningsresultat", "ดูผลการสแกน", "Переглянути результати сканування", "Xem kết quả quét"],
    "overview.localOnly": ["Сканирането се извършва изцяло на този Mac.", "Skenování probíhá celé na tomto Macu.", "Scanningen kører helt på denne Mac.", "Η σάρωση εκτελείται εξ ολοκλήρου σε αυτό το Mac.", "El análisis se ejecuta por completo en este Mac.", "Skannaus suoritetaan kokonaan tällä Macilla.", "A vizsgálat teljes egészében ezen a Macen fut.", "Pemindaian berjalan sepenuhnya di Mac ini.", "Imbasan dijalankan sepenuhnya pada Mac ini.", "Skanningen kjører helt på denne Macen.", "A verificação é executada inteiramente neste Mac.", "Scanarea rulează în întregime pe acest Mac.", "Skanningen körs helt på den här Macen.", "การสแกนทำงานทั้งหมดบน Mac เครื่องนี้", "Сканування виконується повністю на цьому Mac.", "Quá trình quét chạy hoàn toàn trên Mac này."],
    "overview.diskUsageDetail": ["%@ свободни, общо %@", "%@ volných, %@ celkem", "%@ ledig, %@ i alt", "%@ ελεύθερα, %@ συνολικά", "%@ libres, %@ en total", "%@ vapaana, %@ yhteensä", "%@ szabad, %@ összesen", "%@ tersedia, %@ total", "%@ kosong, %@ jumlah", "%@ ledig, %@ totalt", "%@ livres, %@ no total", "%@ liberi, %@ în total", "%@ ledigt, %@ totalt", "ว่าง %@, รวม %@", "%@ вільно, усього %@", "Trống %@, tổng %@"],
    "overview.lastCleanupTitle": ["Освободено при последното почистване", "Poslední čištění uvolnilo", "Seneste oprydning frigav", "Ο τελευταίος καθαρισμός ελευθέρωσε", "Liberado en la última limpieza", "Viimeisin siivous vapautti", "Az utolsó tisztítás felszabadított", "Pembersihan terakhir membebaskan", "Pembersihan terakhir melepaskan", "Siste opprydding frigjorde", "Libertado na última limpeza", "Ultima curățare a eliberat", "Senaste rensningen frigjorde", "การทำความสะอาดครั้งล่าสุดปลดปล่อย", "Звільнено минулого разу", "Lần dọn dẹp cuối đã giải phóng"],
    "overview.lastCleanupMeta": ["%@ · %d елемента · преместени в Кошчето", "%@ · položky: %d · přesunuto do Koše", "%@ · %d elementer · flyttet til Papirkurven", "%@ · %d στοιχεία · μετακινήθηκαν στον Κάδο", "%@ · %d elementos · movidos a la Papelera", "%@ · %d kohdetta · siirretty Roskakoriin", "%@ · %d elem · Kukába helyezve", "%@ · %d item · dipindahkan ke Tempat Sampah", "%@ · %d item · dialihkan ke Tong Sampah", "%@ · %d elementer · flyttet til Papirkurven", "%@ · %d itens · movidos para o Lixo", "%@ · %d elemente · mutate în Coș", "%@ · %d objekt · flyttade till Papperskorgen", "%@ · %d รายการ · ย้ายไปที่ถังขยะ", "%@ · %d елементів · переміщено в Кошик", "%@ · %d mục · đã chuyển vào Thùng rác"],
    "overview.selectedSummary": ["Избрани: %d, %@", "Vybráno: %d, %@", "%d valgt, %@", "%d επιλεγμένα, %@", "%d seleccionados, %@", "%d valittu, %@", "%d kijelölve, %@", "%d dipilih, %@", "%d dipilih, %@", "%d valgt, %@", "%d selecionados, %@", "%d selectate, %@", "%d markerade, %@", "เลือกแล้ว %d รายการ, %@", "Вибрано: %d, %@", "Đã chọn %d, %@"],
    "overview.moreItems": ["%d по-малки елемента, общо %@", "Menší položky: %d, celkem %@", "%d mindre elementer, %@ i alt", "%d μικρότερα στοιχεία, %@ συνολικά", "%d elementos más pequeños, %@ en total", "%d pienempää kohdetta, %@ yhteensä", "%d kisebb elem, összesen %@", "%d item lebih kecil, %@ total", "%d item lebih kecil, %@ jumlah", "%d mindre elementer, %@ totalt", "%d itens mais pequenos, %@ no total", "%d elemente mai mici, %@ în total", "%d mindre objekt, %@ totalt", "%d รายการที่เล็กกว่า, รวม %@", "%d менших елементів, усього %@", "%d mục nhỏ hơn, tổng %@"],
    "overview.showAll": ["Покажете всички", "Zobrazit vše", "Vis alle", "Εμφάνιση όλων", "Mostrar todo", "Näytä kaikki", "Összes megjelenítése", "Tampilkan semua", "Tunjukkan semua", "Vis alle", "Mostrar tudo", "Arată tot", "Visa alla", "แสดงทั้งหมด", "Показати все", "Hiện tất cả"],
    "overview.historyLocal": ["Историята остава на този Mac; нищо не се синхронизира или качва.", "Historie zůstává na tomto Macu; nic se nesynchronizuje ani neodesílá.", "Historikken bliver på denne Mac; intet synkroniseres eller uploades.", "Το ιστορικό παραμένει σε αυτό το Mac, τίποτα δεν συγχρονίζεται ή μεταφορτώνεται.", "El historial permanece en este Mac; no se sincroniza ni se sube.", "Historia pysyy tällä Macilla; mitään ei synkronoida tai ladata.", "Az előzmények ezen a Macen maradnak; semmi nem szinkronizálódik vagy töltődik fel.", "Riwayat tetap di Mac ini; tidak ada yang disinkronkan atau diunggah.", "Sejarah kekal pada Mac ini; tiada apa-apa disegerakkan atau dimuat naik.", "Historikken blir på denne Macen; ingenting synkroniseres eller lastes opp.", "O histórico fica neste Mac; nada é sincronizado nem enviado.", "Istoricul rămâne pe acest Mac; nimic nu este sincronizat sau încărcat.", "Historiken stannar på den här Macen; inget synkroniseras eller laddas upp.", "ประวัติอยู่ใน Mac เครื่องนี้ ไม่มีการซิงค์หรืออัปโหลด", "Історія зберігається на цьому Mac; нічого не синхронізується й не завантажується.", "Lịch sử ở lại trên Mac này; không có gì được đồng bộ hay tải lên."],
    "overview.activityScan": ["Сканирането е завършено, %d елемента", "Skenování dokončeno, %d položek", "Scanning fuldført, %d elementer", "Η σάρωση ολοκληρώθηκε, %d στοιχεία", "Análisis completado, %d elementos", "Skannaus valmis, %d kohdetta", "Vizsgálat befejezve, %d elem", "Pemindaian selesai, %d item", "Imbasan selesai, %d item", "Skanning fullført, %d elementer", "Verificação concluída, %d itens", "Scanare finalizată, %d elemente", "Skanning klar, %d objekt", "สแกนเสร็จแล้ว, %d รายการ", "Сканування завершено, %d елементів", "Đã quét xong, %d mục"],
    "overview.activityUninstall": ["Съвет за деинсталиране, %d приложения не са отваряни скоро", "Doporučení k odinstalaci, aplikace nedávno neotevřené: %d", "Afinstallationsforslag, %d apps ikke åbnet for nylig", "Συμβουλή απεγκατάστασης, %d εφαρμογές δεν άνοιξαν πρόσφατα", "Sugerencia de desinstalación, %d aplicaciones sin abrir recientemente", "Poistoehdotus, %d sovellusta ei avattu äskettäin", "Eltávolítási javaslat, %d alkalmazás nem nyílt meg nemrég", "Saran penghapusan, %d aplikasi tidak dibuka baru-baru ini", "Nasihat nyahpasang, %d apl tidak dibuka baru-baru ini", "Avinstalleringsråd, %d apper ikke åpnet nylig", "Sugestão de desinstalação, %d aplicações não abertas recentemente", "Sfat de dezinstalare, %d aplicații nedeschise recent", "Avinstallationsråd, %d appar har inte öppnats nyligen", "คำแนะนำการถอนการติดตั้ง, %d แอปที่ไม่ได้เปิดล่าสุด", "Порада щодо видалення, %d програм не відкривали нещодавно", "Gợi ý gỡ cài đặt, %d ứng dụng không mở gần đây"],
    "overview.activityStorage": ["Хранилището е анализирано, измерени %@", "Úložiště analyzováno, změřeno %@", "Lagerplads analyseret, %@ målt", "Η αποθήκευση αναλύθηκε, μετρήθηκαν %@", "Almacenamiento analizado, %@ medidos", "Tallennustila analysoitu, %@ mitattu", "Tárhely elemezve, %@ megmérve", "Penyimpanan dianalisis, %@ diukur", "Storan dianalisis, %@ diukur", "Lagring analysert, %@ målt", "Armazenamento analisado, %@ medidos", "Stocare analizată, %@ măsurați", "Lagring analyserad, %@ uppmätt", "วิเคราะห์พื้นที่เก็บข้อมูลแล้ว, วัดได้ %@", "Сховище проаналізовано, виміряно %@", "Đã phân tích dung lượng, đo được %@"],
    "scan.filter.all": ["Всички", "Vše", "Alle", "Όλα", "Todo", "Kaikki", "Mind", "Semua", "Semua", "Alle", "Tudo", "Toate", "Alla", "ทั้งหมด", "Усі", "Tất cả"],
    "scan.filter.junk": ["Ненужни", "Nepořádek", "Skrald", "Περιττά", "Basura", "Roska", "Szemét", "Sampah", "Sampah", "Søppel", "Inúteis", "Inutile", "Skräp", "ขยะ", "Зайве", "Rác"],
    "scan.filter.large": ["Големи", "Velké", "Store", "Μεγάλα", "Grandes", "Suuret", "Nagy", "Besar", "Besar", "Store", "Grandes", "Mari", "Stora", "ขนาดใหญ่", "Великі", "Lớn"],
    "scan.filter.old": ["Стари", "Staré", "Gamle", "Παλιά", "Antiguos", "Vanhat", "Régi", "Lama", "Lama", "Gamle", "Antigos", "Vechi", "Gamla", "เก่า", "Старі", "Cũ"],
    "scan.filter.duplicates": ["Дубликати", "Duplikáty", "Dubletter", "Διπλότυπα", "Duplicados", "Kaksoiskappaleet", "Duplikátumok", "Duplikat", "Pendua", "Duplikater", "Duplicados", "Duplicate", "Dubbletter", "ไฟล์ซ้ำ", "Дублікати", "Trùng"],
    "scan.rescan": ["Сканирайте отново", "Skenovat znovu", "Scan igen", "Νέα σάρωση", "Analizar de nuevo", "Skannaa uudelleen", "Vizsgálat újra", "Pindai lagi", "Imbas semula", "Skann igjen", "Verificar novamente", "Scanează din nou", "Skanna igen", "สแกนอีกครั้ง", "Сканувати знову", "Quét lại"],
    "scan.headerStatus": ["Резултати от %@ · %d елемента", "Výsledky z %@ · %d položek", "Resultater fra %@ · %d elementer", "Αποτελέσματα από %@ · %d στοιχεία", "Resultados de %@ · %d elementos", "Tulokset: %@ · %d kohdetta", "Eredmények: %@ · %d elem", "Hasil dari %@ · %d item", "Hasil daripada %@ · %d item", "Resultater fra %@ · %d elementer", "Resultados de %@ · %d itens", "Rezultate din %@ · %d elemente", "Resultat från %@ · %d objekt", "ผลลัพธ์จาก %@ · %d รายการ", "Результати від %@ · %d елементів", "Kết quả từ %@ · %d mục"],
    "scan.results.safeGroup": ["Безопасни за почистване", "Bezpečné k čištění", "Sikkert at rydde", "Ασφαλή για καθαρισμό", "Se puede limpiar", "Turvallista siivota", "Biztonságosan tisztítható", "Aman untuk dibersihkan", "Selamat untuk dibersihkan", "Trygt å rydde", "Pode ser limpo", "Sigur de curățat", "Säkert att rensa", "ล้างได้อย่างปลอดภัย", "Безпечно очистити", "An toàn để dọn"],
    "scan.results.reviewGroup": ["Изискват вашето потвърждение", "Vyžaduje vaše potvrzení", "Kræver din bekræftelse", "Χρειάζονται την επιβεβαίωσή σας", "Requiere tu confirmación", "Vaatii vahvistuksesi", "Az Ön megerősítését igényli", "Memerlukan konfirmasi Anda", "Memerlukan pengesahan anda", "Trenger din bekreftelse", "Requer a sua confirmação", "Necesită confirmarea ta", "Behöver din bekräftelse", "ต้องได้รับการยืนยันจากคุณ", "Потребує вашого підтвердження", "Cần bạn xác nhận"],
    "scan.results.protectedGroup": ["Защитени", "Chráněné", "Beskyttet", "Προστατευμένα", "Protegido", "Suojattu", "Védett", "Dilindungi", "Dilindungi", "Beskyttet", "Protegido", "Protejate", "Skyddat", "ป้องกันอยู่", "Захищено", "Được bảo vệ"],
    "scan.results.defaultSelected": ["Избрани по подразбиране", "Vybráno ve výchozím nastavení", "Valgt som standard", "Επιλεγμένο από προεπιλογή", "Seleccionado por defecto", "Valittu oletuksena", "Alapértelmezés szerint kijelölve", "Dipilih secara default", "Dipilih secara lalai", "Valgt som standard", "Selecionado por predefinição", "Selectate implicit", "Markerad som standard", "เลือกไว้เป็นค่าเริ่มต้น", "Вибрано за замовчуванням", "Được chọn mặc định"],
    "scan.results.reviewHint": ["Потвърдете всеки елемент преди почистване", "Před čištěním potvrďte každou položku", "Bekræft hvert element før oprydning", "Επιβεβαιώστε κάθε στοιχείο πριν από τον καθαρισμό", "Confirma cada elemento antes de limpiar", "Vahvista jokainen kohde ennen siivousta", "Tisztítás előtt erősítsen meg minden elemet", "Konfirmasi setiap item sebelum membersihkan", "Sahkan setiap item sebelum membersihkan", "Bekreft hvert element før opprydding", "Confirme cada item antes de limpar", "Confirmă fiecare element înainte de curățare", "Bekräfta varje objekt innan rensning", "ยืนยันแต่ละรายการก่อนทำความสะอาด", "Підтвердьте кожен елемент перед очищенням", "Xác nhận từng mục trước khi dọn"],
    "scan.results.cleanTitle": ["Това почистване", "Toto čištění", "Denne oprydning", "Αυτός ο καθαρισμός", "Esta limpieza", "Tämä siivous", "Ez a tisztítás", "Pembersihan ini", "Pembersihan ini", "Denne oppryddingen", "Esta limpeza", "Această curățare", "Den här rensningen", "การทำความสะอาดครั้งนี้", "Це очищення", "Lần dọn dẹp này"],
    "scan.results.cleanButton": ["Почистете %d елемента", "Vyčistit položky: %d", "Ryd %d elementer", "Καθαρισμός %d στοιχείων", "Limpiar %d elementos", "Siivoa %d kohdetta", "%d elem tisztítása", "Bersihkan %d item", "Bersihkan %d item", "Rydd %d elementer", "Limpar %d itens", "Curăță %d elemente", "Rensa %d objekt", "ล้าง %d รายการ", "Очистити %d елементів", "Dọn %d mục"],
    "scan.results.trashHint": ["Премества се в Кошчето; може да се възстанови, докато не го изпразните.", "Přesune se do Koše; obnovitelné, dokud jej nevysypete.", "Flyttes til Papirkurven; kan gendannes, indtil du tømmer den.", "Μετακινείται στον Κάδο· ανακτήσιμο μέχρι να τον αδειάσετε.", "Se mueve a la Papelera; recuperable hasta que la vacíes.", "Siirtyy Roskakoriin; palautettavissa, kunnes tyhjennät sen.", "A Kukába kerül; visszaállítható, amíg ki nem üríti.", "Dipindahkan ke Tempat Sampah; dapat dipulihkan sampai Anda mengosongkannya.", "Dialihkan ke Tong Sampah; boleh dipulihkan sehingga anda mengosongkannya.", "Flyttes til Papirkurven; kan gjenopprettes til du tømmer den.", "Movido para o Lixo; recuperável até o esvaziar.", "Mutat în Coș; recuperabil până golești Coșul.", "Flyttas till Papperskorgen; kan återställas tills du tömmer den.", "ย้ายไปที่ถังขยะ กู้คืนได้จนกว่าจะล้างถังขยะ", "Переміщується в Кошик; можна відновити, доки не спорожнено його.", "Được chuyển vào Thùng rác; có thể khôi phục cho đến khi làm trống."],
    "scan.results.protectedHint": ["Системни файлове и защитени места се пропускат автоматично", "Systémové soubory a chráněná místa se přeskakují automaticky", "Systemfiler og beskyttede placeringer springes automatisk over", "Τα αρχεία συστήματος και οι προστατευμένες τοποθεσίες παραλείπονται αυτόματα", "Los archivos del sistema y las ubicaciones protegidas se omiten automáticamente", "Järjestelmätiedostot ja suojatut sijainnit ohitetaan automaattisesti", "A rendszerfájlok és a védett helyek automatikusan kimaradnak", "File sistem dan lokasi yang dilindungi dilewati secara otomatis", "Fail sistem dan lokasi dilindungi dilangkau secara automatik", "Systemfiler og beskyttede steder hoppes automatisk over", "Ficheiros do sistema e locais protegidos são ignorados automaticamente", "Fișierele de sistem și locațiile protejate sunt ignorate automat", "Systemfiler och skyddade platser hoppas över automatiskt", "ไฟล์ระบบและตำแหน่งที่ได้รับการป้องกันจะถูกข้ามโดยอัตโนมัติ", "Системні файли й захищені місця пропускаються автоматично", "Tệp hệ thống và vị trí được bảo vệ được tự động bỏ qua"],
    "scan.results.reportHint": ["Върнете от Кошчето или експортирайте отчет за почистването.", "Obnovte z Koše nebo exportujte zprávu o čištění.", "Gendan fra Papirkurven, eller eksporter en oprydningsrapport.", "Επαναφέρετε από τον Κάδο ή εξαγάγετε μια αναφορά καθαρισμού.", "Restaura desde la Papelera o exporta un informe de limpieza.", "Palauta Roskakorista tai vie siivousraportti.", "Állítsa vissza a Kukából, vagy exportáljon tisztítási jelentést.", "Pulihkan dari Tempat Sampah, atau ekspor laporan pembersihan.", "Pulihkan daripada Tong Sampah, atau eksport laporan pembersihan.", "Gjenopprett fra Papirkurven, eller eksporter en oppryddingsrapport.", "Restaure a partir do Lixo ou exporte um relatório de limpeza.", "Restaurează din Coș sau exportă un raport de curățare.", "Återställ från Papperskorgen eller exportera en rensningsrapport.", "กู้คืนจากถังขยะ หรือส่งออกรายงานการทำความสะอาด", "Відновіть із Кошика або експортуйте звіт про очищення.", "Khôi phục từ Thùng rác hoặc xuất báo cáo dọn dẹp."],
    "scan.results.sortSize": ["По размер", "Podle velikosti", "Efter størrelse", "Κατά μέγεθος", "Por tamaño", "Koon mukaan", "Méret szerint", "Menurut ukuran", "Mengikut saiz", "Etter størrelse", "Por tamanho", "După dimensiune", "Efter storlek", "ตามขนาด", "За розміром", "Theo kích thước"],
    "scan.results.sortName": ["По име", "Podle názvu", "Efter navn", "Κατά όνομα", "Por nombre", "Nimen mukaan", "Név szerint", "Menurut nama", "Mengikut nama", "Etter navn", "Por nome", "După nume", "Efter namn", "ตามชื่อ", "За назвою", "Theo tên"],
    "scan.results.sortModified": ["По дата на промяна", "Podle data změny", "Efter ændringsdato", "Κατά ημερομηνία τροποποίησης", "Por fecha de modificación", "Muutospäivämäärän mukaan", "Módosítás dátuma szerint", "Menurut tanggal modifikasi", "Mengikut tarikh pengubahsuaian", "Etter endringsdato", "Por data de modificação", "După data modificării", "Efter ändringsdatum", "ตามวันที่แก้ไข", "За датою зміни", "Theo ngày sửa đổi"],
    "scan.results.categoryTotals": ["По категории: %@", "Podle kategorie: %@", "Efter kategori: %@", "Ανά κατηγορία: %@", "Por categoría: %@", "Kategorioittain: %@", "Kategória szerint: %@", "Menurut kategori: %@", "Mengikut kategori: %@", "Etter kategori: %@", "Por categoria: %@", "Pe categorii: %@", "Efter kategori: %@", "ตามหมวดหมู่: %@", "За категоріями: %@", "Theo danh mục: %@"],
    "scan.running.status": ["Сканиране, стъпка %d от %d", "Skenování, krok %d z %d", "Scanner, trin %d af %d", "Σάρωση, βήμα %d από %d", "Analizando, paso %d de %d", "Skannataan, vaihe %d / %d", "Vizsgálat, %d. lépés / %d", "Memindai, langkah %d dari %d", "Mengimbas, langkah %d daripada %d", "Skanner, trinn %d av %d", "A verificar, passo %d de %d", "Se scanează, pasul %d din %d", "Skannar, steg %d av %d", "กำลังสแกน, ขั้นตอน %d จาก %d", "Сканування, крок %d із %d", "Đang quét, bước %d trên %d"],
    "scan.running.step": ["Стъпка %d от %d", "Krok %d z %d", "Trin %d af %d", "Βήμα %d από %d", "Paso %d de %d", "Vaihe %d / %d", "%d. lépés / %d", "Langkah %d dari %d", "Langkah %d daripada %d", "Trinn %d av %d", "Passo %d de %d", "Pasul %d din %d", "Steg %d av %d", "ขั้นตอน %d จาก %d", "Крок %d із %d", "Bước %d trên %d"],
    "scan.running.target": ["Текуща цел", "Aktuální cíl", "Aktuelt mål", "Τρέχων στόχος", "Objetivo actual", "Nykyinen kohde", "Aktuális cél", "Target saat ini", "Sasaran semasa", "Gjeldende mål", "Alvo atual", "Ținta curentă", "Aktuellt mål", "เป้าหมายปัจจุบัน", "Поточна ціль", "Mục tiêu hiện tại"],
    "scan.running.walked": ["Прегледани файлове: %@", "Projito souborů: %@", "%@ filer gennemgået", "%@ αρχεία διατρέχτηκαν", "%@ archivos recorridos", "%@ tiedostoa käyty läpi", "%@ fájl bejárva", "%@ file ditelusuri", "%@ fail ditelusuri", "%@ filer gjennomgått", "%@ ficheiros percorridos", "%@ fișiere parcurse", "%@ filer genomgångna", "เดินผ่าน %@ ไฟล์", "Переглянуто файлів: %@", "Đã duyệt %@ tệp"],
    "scan.running.found": ["Намерени %@", "Nalezeno: %@", "%@ fundet", "%@ βρέθηκαν", "%@ encontrados", "%@ löytyi", "%@ találat", "%@ ditemukan", "%@ ditemui", "%@ funnet", "%@ encontrados", "%@ găsite", "%@ hittade", "พบ %@", "Знайдено %@", "Tìm thấy %@"],
    "scan.running.elapsed": ["Изминало време", "Uplynulo", "Forløbet", "Χρόνος που πέρασε", "Tiempo transcurrido", "Kulunut aika", "Eltelt idő", "Waktu berjalan", "Masa berlalu", "Forløpt", "Tempo decorrido", "Timp scurs", "Förfluten tid", "เวลาที่ผ่านไป", "Минуло", "Thời gian đã qua"],
    "scan.running.phase": ["Текуща фаза", "Aktuální fáze", "Aktuel fase", "Τρέχουσα φάση", "Fase actual", "Nykyinen vaihe", "Aktuális fázis", "Fase saat ini", "Fasa semasa", "Gjeldende fase", "Fase atual", "Faza curentă", "Aktuell fas", "ขั้นตอนปัจจุบัน", "Поточна фаза", "Giai đoạn hiện tại"],
    "scan.running.readOnly": ["Четат се само имена, размери и дати на промяна. Файловете никога не се отварят и нищо не се качва.", "Čte pouze názvy, velikosti a data změny. Nikdy neotevírá soubory ani neodesílá data.", "Læser kun navne, størrelser og ændringsdatoer. Åbner aldrig filer eller uploader data.", "Διαβάζει μόνο ονόματα, μεγέθη και ημερομηνίες τροποποίησης. Δεν ανοίγει ποτέ αρχεία και δεν μεταφορτώνει δεδομένα.", "Solo lee nombres, tamaños y fechas de modificación. Nunca abre archivos ni sube datos.", "Lukee vain nimet, koot ja muutospäivämäärät. Ei koskaan avaa tiedostoja tai lataa tietoja.", "Csak neveket, méreteket és módosítási dátumokat olvas. Soha nem nyit meg fájlokat, és nem tölt fel adatokat.", "Hanya membaca nama, ukuran, dan tanggal modifikasi. Tidak pernah membuka file atau mengunggah data.", "Hanya membaca nama, saiz dan tarikh pengubahsuaian. Ia tidak pernah membuka fail atau memuat naik data.", "Leser bare navn, størrelser og endringsdatoer. Åpner aldri filer eller laster opp data.", "Lê apenas nomes, tamanhos e datas de modificação. Nunca abre ficheiros nem envia dados.", "Citește doar nume, dimensiuni și date de modificare. Nu deschide niciodată fișiere și nu încarcă date.", "Läser bara namn, storlekar och ändringsdatum. Öppnar aldrig filer eller laddar upp data.", "อ่านเฉพาะชื่อ ขนาด และวันที่แก้ไข ไม่เคยเปิดไฟล์หรืออัปโหลดข้อมูล", "Читаються лише назви, розміри й дати зміни. Файли ніколи не відкриваються, і нічого не завантажується.", "Chỉ đọc tên, kích thước và ngày sửa đổi. Không bao giờ mở tệp hay tải dữ liệu lên."],
    "scan.running.categories": ["Намерени по категории", "Nalezeno podle kategorie", "Fundet efter kategori", "Βρέθηκαν ανά κατηγορία", "Encontrado por categoría", "Löydetty kategorioittain", "Kategória szerint talált", "Ditemukan menurut kategori", "Ditemui mengikut kategori", "Funnet etter kategori", "Encontrado por categoria", "Găsite pe categorii", "Hittade per kategori", "พบตามหมวดหมู่", "Знайдено за категоріями", "Tìm thấy theo danh mục"],
    "scan.running.categoryCount": ["%d категории", "Kategorie: %d", "%d kategorier", "%d κατηγορίες", "%d categorías", "%d kategoriaa", "%d kategória", "%d kategori", "%d kategori", "%d kategorier", "%d categorias", "Categorii: %d", "%d kategorier", "%d หมวดหมู่", "%d категорій", "%d danh mục"],
    "scan.running.waiting": ["Изчакване", "Čekání", "Venter", "Σε αναμονή", "En espera", "Odottaa", "Várakozás", "Menunggu", "Menunggu", "Venter", "Em espera", "Se așteaptă", "Väntar", "กำลังรอ", "Очікування", "Đang chờ"],
    "scan.running.finding": ["Търсене", "Hledání", "Finder", "Εύρεση", "Buscando", "Etsii", "Keresés", "Menemukan", "Mencari", "Finner", "A encontrar", "Se caută", "Söker", "กำลังค้นหา", "Пошук", "Đang tìm"],
    "apps.status": ["Инсталирани: %d · не отваряни от 6 месеца: %d", "Nainstalováno: %d · neotevřeno 6 měsíců: %d", "Installeret %d · %d ikke åbnet i 6 måneder", "Εγκατεστημένες %d · %d δεν άνοιξαν σε 6 μήνες", "%d instaladas · %d sin abrir en 6 meses", "Asennettu %d · %d ei avattu 6 kuukauteen", "%d telepítve · %d nem nyílt meg 6 hónapja", "%d terpasang · %d tidak dibuka dalam 6 bulan", "%d dipasang · %d tidak dibuka dalam 6 bulan", "Installert %d · %d ikke åpnet på 6 måneder", "%d instaladas · %d não abertas há 6 meses", "%d instalate · %d nedeschise în 6 luni", "Installerade %d · %d inte öppnade på 6 månader", "ติดตั้ง %d · %d แอปที่ไม่ได้เปิดใน 6 เดือน", "Встановлено: %d · не відкривано 6 місяців: %d", "Đã cài %d · %d ứng dụng không mở trong 6 tháng"],
    "apps.listTitle": ["Приложения", "Aplikace", "Programmer", "Εφαρμογές", "Aplicaciones", "Sovellukset", "Alkalmazások", "Aplikasi", "Aplikasi", "Apper", "Aplicações", "Aplicații", "Program", "แอปพลิเคชัน", "Програми", "Ứng dụng"],
    "apps.sortSummary": ["Сортирани по размер · общо %@", "Seřazeno podle velikosti · celkem %@", "Sorteret efter størrelse · %@ i alt", "Ταξινόμηση κατά μέγεθος · %@ συνολικά", "Ordenadas por tamaño · %@ en total", "Lajiteltu koon mukaan · %@ yhteensä", "Méret szerint rendezve · összesen %@", "Diurutkan menurut ukuran · %@ total", "Diisih mengikut saiz · %@ jumlah", "Sortert etter størrelse · %@ totalt", "Ordenadas por tamanho · %@ no total", "Sortate după dimensiune · %@ în total", "Sorterat efter storlek · %@ totalt", "เรียงตามขนาด · รวม %@", "Сортовано за розміром · усього %@", "Sắp xếp theo kích thước · tổng %@"],
    "apps.reclaimable": ["Може да се освободи", "Lze uvolnit", "Kan frigives", "Μπορούν να ελευθερωθούν", "Se puede liberar", "Vapautettavissa", "Felszabadítható", "Dapat dibebaskan", "Boleh dilepaskan", "Kan frigjøres", "Pode ser libertado", "Poate fi eliberat", "Kan frigöras", "ปลดปล่อยได้", "Можна звільнити", "Có thể giải phóng"],
    "apps.appAndRelated": ["Приложение %@, свързани файлове %@", "Aplikace %@, související soubory %@", "App %@, relaterede filer %@", "Εφαρμογή %@, σχετικά αρχεία %@", "Aplicación %@, archivos relacionados %@", "Sovellus %@, liittyvät tiedostot %@", "Alkalmazás: %@, kapcsolódó fájlok: %@", "Aplikasi %@, file terkait %@", "Apl %@, fail berkaitan %@", "App %@, tilknyttede filer %@", "Aplicação %@, ficheiros relacionados %@", "Aplicație %@, fișiere asociate %@", "App %@, relaterade filer %@", "แอป %@, ไฟล์ที่เกี่ยวข้อง %@", "Програма %@, пов'язані файли %@", "Ứng dụng %@, tệp liên quan %@"],
    "apps.relatedWillRemove": ["Свързани файлове за премахване", "Související soubory k odstranění", "Relaterede filer, der fjernes", "Σχετικά αρχεία προς αφαίρεση", "Archivos relacionados que se eliminarán", "Poistettavat liittyvät tiedostot", "Eltávolítandó kapcsolódó fájlok", "File terkait yang akan dihapus", "Fail berkaitan untuk dibuang", "Tilknyttede filer som fjernes", "Ficheiros relacionados a eliminar", "Fișiere asociate de eliminat", "Relaterade filer som tas bort", "ไฟล์ที่เกี่ยวข้องที่จะลบ", "Пов'язані файли до видалення", "Tệp liên quan sẽ xóa"],
    "apps.uninstallAndClean": ["Деинсталирайте и почистете %@", "Odinstalovat a vyčistit %@", "Afinstaller og ryd %@", "Απεγκατάσταση και καθαρισμός %@", "Desinstalar y limpiar %@", "Poista asennus ja siivoa %@", "%@ eltávolítása és tisztítása", "Hapus dan bersihkan %@", "Nyahpasang dan bersihkan %@", "Avinstaller og rydd %@", "Desinstalar e limpar %@", "Dezinstalează și curăță %@", "Avinstallera och rensa %@", "ถอนการติดตั้งและล้าง %@", "Видалити й очистити %@", "Gỡ cài đặt và dọn %@"],
    "apps.restoreHint": ["Може да се върне от Кошчето, докато не го изпразните", "Obnovitelné z Koše, dokud jej nevysypete", "Kan gendannes fra Papirkurven, indtil du tømmer den", "Ανακτήσιμα από τον Κάδο μέχρι να τον αδειάσετε", "Recuperable desde la Papelera hasta que la vacíes", "Palautettavissa Roskakorista, kunnes tyhjennät sen", "A Kukából visszaállítható, amíg ki nem üríti", "Dapat dipulihkan dari Tempat Sampah sampai Anda mengosongkannya", "Boleh dipulihkan daripada Tong Sampah sehingga anda mengosongkannya", "Kan gjenopprettes fra Papirkurven til du tømmer den", "Recuperável a partir do Lixo até o esvaziar", "Recuperabil din Coș până îl golești", "Kan återställas från Papperskorgen tills du tömmer den", "กู้คืนได้จากถังขยะจนกว่าจะล้างถังขยะ", "Можна відновити з Кошика, доки не спорожнено його", "Có thể khôi phục từ Thùng rác cho đến khi làm trống"],
    "apps.footer": ["Показани са приложения над 200 MB · общо %d", "Zobrazeny aplikace nad 200 MB · celkem %d", "Viser apps over 200 MB · %d i alt", "Εμφάνιση εφαρμογών άνω των 200 MB · %d συνολικά", "Se muestran aplicaciones de más de 200 MB · %d en total", "Näytetään yli 200 Mt:n sovellukset · %d yhteensä", "A 200 MB-nál nagyobb alkalmazások láthatók · összesen %d", "Menampilkan aplikasi di atas 200 MB · %d total", "Memaparkan apl melebihi 200 MB · %d jumlah", "Viser apper over 200 MB · %d totalt", "A mostrar aplicações com mais de 200 MB · %d no total", "Se afișează aplicațiile peste 200 MB · %d în total", "Visar appar över 200 MB · %d totalt", "แสดงแอปที่ใหญ่กว่า 200 MB · รวม %d", "Показано програми понад 200 МБ · усього %d", "Đang hiển thị ứng dụng trên 200 MB · tổng %d"],
    "apps.lastOpened": ["Последно отваряне: %@", "Naposledy otevřeno %@", "Senest åbnet %@", "Τελευταίο άνοιγμα %@", "Última apertura: %@", "Viimeksi avattu %@", "Utoljára megnyitva: %@", "Terakhir dibuka %@", "Terakhir dibuka %@", "Sist åpnet %@", "Última abertura: %@", "Ultima deschidere %@", "Senast öppnad %@", "เปิดล่าสุด %@", "Останнє відкриття: %@", "Mở lần cuối %@"],
    "apps.neverOpened": ["Никога не е отваряно", "Nikdy neotevřeno", "Aldrig åbnet", "Δεν άνοιξε ποτέ", "Nunca abierta", "Ei koskaan avattu", "Soha nem nyitották meg", "Belum pernah dibuka", "Tidak pernah dibuka", "Aldri åpnet", "Nunca aberta", "Niciodată deschisă", "Aldrig öppnad", "ไม่เคยเปิด", "Ніколи не відкривано", "Chưa từng mở"],
    "storage.startTitle": ["Вижте какво заема диска", "Podívejte se, co zabírá disk", "Se, hvad der optager disken", "Δείτε τι καταλαμβάνει τον δίσκο", "Mira qué ocupa el disco", "Näe, mikä vie levytilaa", "Nézze meg, mi foglalja el a lemezt", "Lihat apa yang menempati disk", "Lihat apa yang menggunakan cakera", "Se hva som tar plass på disken", "Veja o que ocupa o disco", "Vezi ce ocupă discul", "Se vad som tar plats på disken", "ดูว่าอะไรใช้พื้นที่ดิสก์", "Побачте, що займає диск", "Xem điều gì chiếm dung lượng đĩa"],
    "storage.status": ["%@ · %@ заети от %@", "%@ · %@ využito z %@", "%@ · %@ brugt af %@", "%@ · %@ σε χρήση από %@", "%@ · %@ usados de %@", "%@ · %@ käytössä %@:sta", "%@ · %@ használt a következőből: %@", "%@ · %@ terpakai dari %@", "%@ · %@ digunakan daripada %@", "%@ · %@ brukt av %@", "%@ · %@ utilizados de %@", "%@ · %@ utilizați din %@", "%@ · %@ använt av %@", "%@ · ใช้ไป %@ จาก %@", "%@ · зайнято %@ із %@", "%@ · đã dùng %@ trên %@"],
    "storage.spaceDistribution": ["Разпределение на пространството", "Rozložení místa", "Pladsfordeling", "Κατανομή χώρου", "Distribución del espacio", "Tilan jakautuminen", "Területeloszlás", "Distribusi ruang", "Taburan ruang", "Plassfordeling", "Distribuição do espaço", "Distribuția spațiului", "Utrymmesfördelning", "การกระจายของพื้นที่", "Розподіл простору", "Phân bổ dung lượng"],
    "storage.categoryDetail": ["Разбивка по категории", "Rozpis kategorií", "Kategorioversigt", "Ανάλυση ανά κατηγορία", "Desglose por categoría", "Kategoriaerittely", "Kategóriabontás", "Rincian kategori", "Pecahan kategori", "Kategorioversikt", "Repartição por categoria", "Defalcare pe categorii", "Kategoriöversikt", "รายละเอียดตามหมวดหมู่", "Розподіл за категоріями", "Chi tiết theo danh mục"],
    "storage.usageShare": ["Използване", "Využití", "Forbrug", "Χρήση", "Uso", "Käyttö", "Használat", "Penggunaan", "Penggunaan", "Bruk", "Utilização", "Utilizare", "Användning", "การใช้งาน", "Використано", "Mức sử dụng"],
    "storage.availableSpace": ["Свободно", "Dostupné", "Tilgængelig", "Διαθέσιμος", "Disponible", "Saatavilla", "Elérhető", "Tersedia", "Tersedia", "Tilgjengelig", "Disponível", "Disponibil", "Tillgängligt", "ใช้ได้", "Вільно", "Khả dụng"],
    "storage.localNote": ["Измерено на този Mac. Нищо не се качва или изпраща онлайн.", "Změřeno na tomto Macu. Nic se neodesílá ani neposílá online.", "Målt på denne Mac. Intet uploades eller sendes online.", "Μετρήθηκε σε αυτό το Mac. Τίποτα δεν μεταφορτώνεται ή αποστέλλεται στο διαδίκτυο.", "Medido en este Mac. No se sube ni se envía nada.", "Mitattu tällä Macilla. Mitään ei ladata tai lähetetä verkkoon.", "Ezen a Macen mérve. Semmi nem kerül feltöltésre vagy online elküldésre.", "Diukur di Mac ini. Tidak ada yang diunggah atau dikirim online.", "Diukur pada Mac ini. Tiada apa-apa dimuat naik atau dihantar ke dalam talian.", "Målt på denne Macen. Ingenting lastes opp eller sendes online.", "Medido neste Mac. Nada é enviado para a Internet.", "Măsurat pe acest Mac. Nimic nu este încărcat sau trimis online.", "Uppmätt på den här Macen. Inget laddas upp eller skickas online.", "วัดบน Mac เครื่องนี้ ไม่มีการอัปโหลดหรือส่งข้อมูลออนไลน์", "Виміряно на цьому Mac. Нічого не завантажується й не надсилається в мережу.", "Được đo trên Mac này. Không có gì được tải lên hay gửi trực tuyến."],
    "storage.suggestionTitle": ["Предложение", "Doporučení", "Forslag", "Πρόταση", "Sugerencia", "Ehdotus", "Javaslat", "Saran", "Cadangan", "Forslag", "Sugestão", "Sugestie", "Förslag", "ข้อเสนอแนะ", "Порада", "Gợi ý"],
    "storage.cleanableHeading": ["%@ може да се почисти", "Lze vyčistit %@", "%@ kan ryddes", "%@ μπορούν να καθαριστούν", "Se pueden limpiar %@", "%@ voidaan siivota", "%@ tisztítható", "%@ dapat dibersihkan", "%@ boleh dibersihkan", "%@ kan ryddes", "%@ podem ser limpos", "%@ poate fi curățat", "%@ kan rensas", "ล้างได้ %@", "Можна очистити %@", "Có thể dọn %@"],
    "storage.suggestionDetail": ["Започнете с кешове и стари инсталатори, след което сканирайте отново, за да потвърдите.", "Začněte mezipamětmi a starými instalátory, poté skenujte znovu pro potvrzení.", "Begynd med caches og gamle installationsprogrammer, og scan derefter igen.", "Ξεκινήστε με cache και παλιά προγράμματα εγκατάστασης και, στη συνέχεια, σαρώστε ξανά για επιβεβαίωση.", "Empieza por las cachés y los instaladores antiguos; después vuelve a analizar para confirmar.", "Aloita välimuisteista ja vanhoista asennusohjelmista ja skannaa sitten uudelleen.", "Kezdje a gyorsítótárakkal és a régi telepítőkkel, majd vizsgáljon újra az ellenőrzéshez.", "Mulai dengan cache dan penginstal lama, lalu pindai lagi untuk memastikan.", "Mulakan dengan cache dan pemasang lama, kemudian imbas semula untuk mengesahkan.", "Begynn med cacher og gamle installasjonsprogrammer, og skann deretter på nytt.", "Comece pelas caches e pelos instaladores antigos e, em seguida, verifique novamente para confirmar.", "Începe cu cache-urile și instalatoarele vechi, apoi scanează din nou pentru a confirma.", "Börja med cacher och gamla installationsprogram och skanna sedan igen.", "เริ่มจากแคชและไฟล์ติดตั้งเก่า แล้วสแกนอีกครั้งเพื่อยืนยัน", "Почніть із кешів і старих інсталяторів, потім скануйте знову, щоб підтвердити.", "Bắt đầu với bộ nhớ đệm và bộ cài cũ, rồi quét lại để xác nhận."],
    "storage.goClean": ["Към почистване", "Přejít k čištění", "Ryd op", "Μετάβαση στον καθαρισμό", "Ir a limpiar", "Siivoa", "Tisztítás indítása", "Bersihkan", "Pergi bersihkan", "Rydd opp", "Ir para a limpeza", "Mergi la curățare", "Rensa", "ไปทำความสะอาด", "До очищення", "Đi dọn dẹp"],
    "settings.headerStatus": ["Настройки, Sift %@", "Nastavení, Sift %@", "Indstillinger, Sift %@", "Ρυθμίσεις, Sift %@", "Ajustes, Sift %@", "Asetukset, Sift %@", "Beállítások, Sift %@", "Pengaturan, Sift %@", "Tetapan, Sift %@", "Innstillinger, Sift %@", "Definições, Sift %@", "Configurări, Sift %@", "Inställningar, Sift %@", "การตั้งค่า, Sift %@", "Налаштування, Sift %@", "Cài đặt, Sift %@"],
    "language.search": ["Търсене на езици", "Hledat jazyky", "Søg efter sprog", "Αναζήτηση γλωσσών", "Buscar idiomas", "Hae kieliä", "Nyelvek keresése", "Cari bahasa", "Cari bahasa", "Søk etter språk", "Pesquisar idiomas", "Caută limbi", "Sök språk", "ค้นหาภาษา", "Пошук мов", "Tìm ngôn ngữ"],
    "language.noResults": ["Няма съвпадащ език", "Žádný odpovídající jazyk", "Ingen matchende sprog", "Δεν βρέθηκε γλώσσα", "No hay idiomas coincidentes", "Ei vastaavaa kieltä", "Nincs egyező nyelv", "Tidak ada bahasa yang cocok", "Tiada bahasa yang sepadan", "Ingen samsvarende språk", "Nenhum idioma correspondente", "Nicio limbă potrivită", "Inget matchande språk", "ไม่พบภาษาที่ตรงกัน", "Немає відповідних мов", "Không có ngôn ngữ phù hợp"],

    # --- Trash and snapshots ---
    "trash.empty.action": ["Изчистване на Кошчето", "Vysypat koš", "Tøm papirkurven", "Άδειασμα Κάδου", "Vaciar la papelera", "Tyhjennä roskakori", "Kuka ürítése", "Kosongkan Tempat Sampah", "Kosongkan Tong Sampah", "Tøm papirkurven", "Esvaziar o Lixo", "Golește coșul", "Töm papperskorgen", "ล้างถังขยะ", "Спорожнити Кошик", "Dọn thùng rác"],
    "trash.empty.message": ["%@ ще бъде изтрито за постоянно. Това не може да бъде отменено.", "%@ bude trvale odstraněno. Akci nelze vrátit.", "%@ slettes permanent. Det kan ikke fortrydes.", "Το %@ θα διαγραφεί οριστικά. Δεν είναι δυνατή η αναίρεση.", "Elimina %@ de forma permanente. No se puede deshacer.", "%@ poistetaan pysyvästi. Toimintoa ei voi perua.", "%@ véglegesen törlődik. Ez nem vonható vissza.", "%@ akan dihapus permanen. Tindakan ini tidak dapat dibatalkan.", "%@ akan dipadam secara kekal. Tindakan ini tidak boleh dibatalkan.", "%@ slettes permanent. Dette kan ikke angres.", "Remove %@ permanentemente. Não é possível anular.", "%@ va fi șters definitiv. Acțiunea nu poate fi anulată.", "%@ raderas permanent. Det går inte att ångra.", "จะลบ %@ อย่างถาวรและไม่สามารถกู้คืนได้", "%@ буде остаточно видалено. Скасувати це неможливо.", "%@ sẽ bị xóa vĩnh viễn. Không thể hoàn tác."],
    "diagnostics.snapshots.openTimeMachine": ["Отваряне на Time Machine", "Otevřít Time Machine", "Åbn Time Machine", "Άνοιγμα Time Machine", "Abrir Time Machine", "Avaa Time Machine", "Time Machine megnyitása", "Buka Time Machine", "Buka Time Machine", "Åpne Time Machine", "Abrir o Time Machine", "Deschide Time Machine", "Öppna Time Machine", "เปิด Time Machine", "Відкрити Time Machine", "Mở Time Machine"],

    # --- Coverage diagnostics ---
    "diagnostics.coverage.title": ["Покритие на правилата", "Pokrytí pravidel", "Regeldækning", "Κάλυψη κανόνων", "Cobertura de reglas", "Sääntöjen kattavuus", "Szabálylefedettség", "Cakupan aturan", "Liputan peraturan", "Regeldekning", "Cobertura de regras", "Acoperirea regulilor", "Regeltäckning", "ความครอบคลุมของกฎ", "Покриття правил", "Độ phủ quy tắc"],
    "diagnostics.coverage.detail": ["Изпълнява едно сканиране с текущата таблица с правила и показва какво е намерило всяко правило и кои големи папки не се покриват от никое.", "Provede jedno skenování s aktuální tabulkou pravidel a ukáže, co každé pravidlo našlo a které velké složky žádné pravidlo nepokrývá.", "Kører én scanning med den aktuelle regeltabel og viser, hvad hver regel fandt, og hvilke store mapper ingen regel når.", "Εκτελεί μία σάρωση με τον τρέχοντα πίνακα κανόνων και δείχνει τι βρήκε κάθε κανόνας και ποιοι μεγάλοι φάκελοι δεν καλύπτονται.", "Ejecuta un análisis con la tabla de reglas actual y muestra qué encontró cada regla y qué carpetas grandes no cubre ninguna.", "Suorittaa yhden skannauksen nykyisellä sääntötaulukolla ja näyttää, mitä kukin sääntö löysi ja mitkä suuret kansiot jäävät ilman sääntöä.", "Egy vizsgálatot futtat a jelenlegi szabálytáblával, és megmutatja, mit talált az egyes szabályok, és mely nagy mappákra nem terjed ki egyik sem.", "Menjalankan satu pemindaian dengan tabel aturan saat ini lalu menunjukkan apa yang ditemukan tiap aturan dan folder besar mana yang tidak dijangkau aturan mana pun.", "Menjalankan satu imbasan dengan jadual peraturan semasa dan menunjukkan apa yang ditemui setiap peraturan serta folder besar yang tiada peraturan mencapainya.", "Kjører én skanning med gjeldende regeltabell og viser hva hver regel fant og hvilke store mapper ingen regel når.", "Executa uma verificação com a tabela de regras atual e mostra o que cada regra encontrou e que pastas grandes nenhuma regra alcança.", "Rulează o scanare cu tabelul de reguli actual și arată ce a găsit fiecare regulă și ce foldere mari nu sunt acoperite de niciuna.", "Kör en skanning med den aktuella regeltabellen och visar vad varje regel hittade och vilka stora mappar ingen regel når.", "สแกนหนึ่งครั้งด้วยตารางกฎปัจจุบัน แล้วแสดงสิ่งที่แต่ละกฎพบและโฟลเดอร์ขนาดใหญ่ที่ไม่มีกฎใดเข้าถึง", "Виконує одне сканування з поточною таблицею правил і показує, що знайшло кожне правило та які великі теки не покриті жодним.", "Chạy một lần quét với bảng quy tắc hiện tại, cho biết mỗi quy tắc tìm thấy gì và thư mục lớn nào không quy tắc nào chạm tới."],
    "diagnostics.coverage.run": ["Проверка на покритието", "Zkontrolovat pokrytí", "Kontrollér dækning", "Έλεγχος κάλυψης", "Comprobar cobertura", "Tarkista kattavuus", "Lefedettség ellenőrzése", "Periksa cakupan", "Semak liputan", "Kontroller dekning", "Verificar cobertura", "Verifică acoperirea", "Kontrollera täckning", "ตรวจสอบความครอบคลุม", "Перевірити покриття", "Kiểm tra độ phủ"],
    "diagnostics.coverage.idle": ["Правила без находки: %@", "Pravidla bez nálezu: %@", "Regler uden fund: %@", "Κανόνες χωρίς ευρήματα: %@", "Reglas sin resultados: %@", "Säännöt ilman tuloksia: %@", "Találat nélküli szabályok: %@", "Aturan tanpa hasil: %@", "Peraturan tanpa hasil: %@", "Regler uten treff: %@", "Regras sem resultados: %@", "Reguli fără rezultate: %@", "Regler utan träff: %@", "กฎที่ไม่พบสิ่งใด: %@", "Правила без знахідок: %@", "Quy tắc không tìm thấy gì: %@"],
    "diagnostics.coverage.uncovered": ["Големи папки без правило", "Velké složky bez pravidla", "Store mapper uden regel", "Μεγάλοι φάκελοι χωρίς κανόνα", "Carpetas grandes sin cobertura", "Suuret kansiot ilman sääntöä", "Nagy mappák szabály nélkül", "Folder besar tanpa aturan", "Folder besar tanpa peraturan", "Store mapper uten regel", "Pastas grandes sem cobertura", "Foldere mari neacoperite", "Stora mappar utan regel", "โฟลเดอร์ขนาดใหญ่ที่ไม่มีกฎ", "Великі теки без правил", "Thư mục lớn không có quy tắc"],
    "diagnostics.coverage.rule": ["Правило", "Pravidlo", "Regel", "Κανόνας", "Regla", "Sääntö", "Szabály", "Aturan", "Peraturan", "Regel", "Regra", "Regulă", "Regel", "กฎ", "Правило", "Quy tắc"],
    "diagnostics.coverage.synthesized": ["Сканиране", "Sken", "Scanning", "Σάρωση", "Escaneo", "Skannaus", "Vizsgálat", "Pemindaian", "Imbasan", "Skanning", "Análise", "Scanare", "Skanning", "สแกน", "Сканування", "Quét"],
    "diagnostics.coverage.synthesizedNote": ["Редовете с „Сканиране“ идват от кода за сканиране — остатъци и прагове за размер и възраст —, а не от файла с правила.", "Řádky označené „Sken“ pocházejí z kódu skenování — zbytky a prahy velikosti a stáří —, nikoli ze souboru pravidel.", "Rækker markeret «Scanning» kommer fra scanningskoden — rester og størrelses- og aldersgrænser — ikke fra regelfilen.", "Οι γραμμές με ένδειξη «Σάρωση» προέρχονται από τον κώδικα σάρωσης — υπολείμματα και όρια μεγέθους και ηλικίας —, όχι από το αρχείο κανόνων.", "Las filas marcadas «Escaneo» provienen del código de escaneo —residuos y umbrales de tamaño y antigüedad—, no del archivo de reglas.", "Merkinnällä »Skannaus» varustetut rivit tulevat skannauskoodista — jäänteet sekä koko- ja ikärajat — eivät sääntötiedostosta.", "A „Vizsgálat” jelölésű sorok a vizsgáló kódból származnak — maradványok, méret- és korhatárok —, nem a szabályfájlból.", "Baris bertanda «Pemindaian» berasal dari kode pemindaian — sisa dan ambang ukuran serta usia — bukan dari berkas aturan.", "Baris bertanda «Imbasan» datang daripada kod imbasan — sisa dan ambang saiz serta usia — bukan daripada fail peraturan.", "Rader merket «Skanning» kommer fra skannekoden — rester og størrelses- og aldersgrenser — ikke fra regelfilen.", "As linhas marcadas «Análise» vêm do código de análise — resíduos e limites de tamanho e idade —, não do ficheiro de regras.", "Rândurile marcate «Scanare» provin din codul de scanare — reziduuri și praguri de dimensiune și vechime —, nu din fișierul de reguli.", "Rader märkta ”Skanning” kommer från skanningskoden — rester och storleks- och åldersgränser — inte från regelfilen.", "แถวที่ทำเครื่องหมาย «สแกน» มาจากโค้ดการสแกน — ของตกค้างและเกณฑ์ขนาดและอายุ — ไม่ใช่จากไฟล์กฎ", "Рядки з позначкою «Сканування» походять із коду сканування — залишки та пороги розміру й віку —, а не з файлу правил.", "Các dòng được đánh dấu «Quét» đến từ mã quét — tàn dư và ngưỡng kích thước cùng tuổi — chứ không từ tệp quy tắc."],

    # --- Rule drafts ---
    "diagnostics.coverage.draftTitle": ["Чернова на правило", "Návrh pravidla", "Regeludkast", "Πρόχειρο κανόνα", "Borrador de regla", "Sääntöluonnos", "Szabálytervezet", "Draf aturan", "Draf peraturan", "Regelutkast", "Rascunho de regra", "Ciornă de regulă", "Regelutkast", "ร่างกฎ", "Чернетка правила", "Bản nháp quy tắc"],
    "diagnostics.coverage.draftDetail": ["Добавете това към своя файл с правила и включете „Използване на собствен файл с правила“ в Настройки. Дотогава нищо не се изтрива.", "Přidejte to do svého souboru pravidel a v Nastavení zapněte „Používat vlastní soubor pravidel“. Do té doby se nic nemaže.", "Føj dette til din egen regelfil, og slå «Brug en brugerdefineret regelfil» til i Indstillinger. Indtil da ryddes intet.", "Προσθέστε το στο δικό σας αρχείο κανόνων και ενεργοποιήστε το «Χρήση προσαρμοσμένου αρχείου κανόνων» στις Ρυθμίσεις. Μέχρι τότε δεν διαγράφεται τίποτα.", "Añade esto a tu propio archivo de reglas y activa «Usar un archivo de reglas propio» en Ajustes. Hasta entonces no se limpia nada.", "Lisää tämä omaan sääntötiedostoosi ja ota Asetuksissa käyttöön ”Käytä mukautettua sääntötiedostoa”. Sitä ennen mitään ei poisteta.", "Adja hozzá ezt a saját szabályfájlhoz, majd a Beállításokban kapcsolja be az „Egyéni szabályfájl használata” lehetőséget. Addig semmi nem törlődik.", "Tambahkan ini ke berkas aturan Anda, lalu aktifkan “Gunakan berkas aturan khusus” di Pengaturan. Sebelum itu tidak ada yang dibersihkan.", "Tambahkan ini pada fail peraturan anda, kemudian hidupkan “Guna fail peraturan tersuai” dalam Tetapan. Sebelum itu tiada apa yang dibersihkan.", "Legg dette til i din egen regelfil og slå på «Bruk en egendefinert regelfil» i Innstillinger. Inntil da ryddes ingenting.", "Adicione isto ao seu próprio ficheiro de regras e ative «Utilizar um ficheiro de regras próprio» nas Definições. Até lá nada é limpo.", "Adaugă asta în propriul fișier de reguli și activează „Folosește un fișier de reguli propriu” în Configurări. Până atunci nu se curăță nimic.", "Lägg till detta i din egen regelfil och slå på ”Använd en anpassad regelfil” i Inställningar. Innan dess rensas ingenting.", "เพิ่มส่วนนี้ในไฟล์กฎของคุณ แล้วเปิด “ใช้ไฟล์กฎที่กำหนดเอง” ในการตั้งค่า ก่อนหน้านั้นจะไม่มีการล้างข้อมูลใด ๆ", "Додайте це до свого файлу правил і ввімкніть «Використовувати власний файл правил» у Налаштуваннях. До того часу нічого не видаляється.", "Thêm phần này vào tệp quy tắc của bạn, rồi bật “Dùng tệp quy tắc tùy chỉnh” trong Cài đặt. Trước đó sẽ không có gì bị xóa."],
    "diagnostics.coverage.draftCopy": ["Копиране", "Kopírovat", "Kopiér", "Αντιγραφή", "Copiar", "Kopioi", "Másolás", "Salin", "Salin", "Kopier", "Copiar", "Copiază", "Kopiera", "คัดลอก", "Копіювати", "Sao chép"],
    "diagnostics.coverage.draftCannot": ["Тази папка не може да се покрие с правило: %@", "Tuto složku nelze pokrýt pravidlem: %@", "Denne mappe kan ikke dækkes af en regel: %@", "Αυτός ο φάκελος δεν μπορεί να καλυφθεί από κανόνα: %@", "Esta carpeta no puede cubrirse con una regla: %@", "Tätä kansiota ei voi kattaa säännöllä: %@", "Ez a mappa nem fedhető le szabállyal: %@", "Folder ini tidak dapat dicakup oleh aturan: %@", "Folder ini tidak boleh diliputi oleh peraturan: %@", "Denne mappen kan ikke dekkes av en regel: %@", "Esta pasta não pode ser coberta por uma regra: %@", "Acest folder nu poate fi acoperit de o regulă: %@", "Den här mappen kan inte täckas av en regel: %@", "โฟลเดอร์นี้ไม่สามารถครอบคลุมด้วยกฎได้: %@", "Цю теку не можна покрити правилом: %@", "Thư mục này không thể được bao phủ bởi quy tắc: %@"],

    # --- Residue categories ---
    "cleanup.category.groupContainerResidue": ["Остатъци от споделени контейнери", "Zbytky sdílených kontejnerů", "Rester af delte containere", "Υπολείμματα κοινόχρηστων περιεκτών", "Residuos de contenedores compartidos", "Jaettujen säilöjen jäänteet", "Megosztott tárolók maradványai", "Sisa kontainer bersama", "Baki bekas bekas bersama", "Rester av delte beholdere", "Resíduos de contentores partilhados", "Reziduuri din containere partajate", "Rester av delade containrar", "เศษของคอนเทนเนอร์ที่ใช้ร่วมกัน", "Залишки спільних контейнерів", "Tàn dư vùng chứa dùng chung"],

    # --- Residue ownership ---
    "uninstall.sharedContainer": ["Споделено също с: %@", "Sdíleno také s: %@", "Deles også med: %@", "Κοινόχρηστο επίσης με: %@", "También compartido con: %@", "Jaettu myös: %@", "Megosztva ezekkel is: %@", "Juga dibagikan dengan: %@", "Turut dikongsi dengan: %@", "Deles også med: %@", "Partilhado também com: %@", "Partajat și cu: %@", "Delas även med: %@", "แชร์ร่วมกับ: %@", "Спільно з: %@", "Chia sẻ với: %@"],
    "scan.results.ownerAction": ["На кое приложение е?", "Které aplikace to je?", "Hvilken app er det?", "Ποιας εφαρμογής είναι;", "¿De qué app es?", "Minkä sovelluksen?", "Melyik alkalmazásé?", "Aplikasi apa ini?", "Aplikasi apa ini?", "Hvilken app er dette?", "De que aplicação é?", "A cărei aplicații este?", "Vilken app är det?", "เป็นของแอปใด", "Якої це програми?", "Của ứng dụng nào?"],
    "scan.results.ownerMissing": ["За %@ не е инсталирано приложение. Идентификаторът е копиран.", "Pro %@ není nainstalována žádná aplikace. Identifikátor byl zkopírován.", "Der er ingen installeret app til %@. Identifikatoren er kopieret.", "Δεν είναι εγκατεστημένη εφαρμογή για %@. Το αναγνωριστικό αντιγράφηκε.", "No hay ninguna aplicación instalada para %@. Se copió el identificador.", "Sovellusta %@ ei ole asennettu. Tunniste kopioitiin.", "A(z) %@ azonosítóhoz nincs telepített alkalmazás. Az azonosító vágólapra került.", "Tidak ada aplikasi terpasang untuk %@. Pengenal telah disalin.", "Tiada aplikasi dipasang untuk %@. Pengecam telah disalin.", "Ingen app er installert for %@. Identifikatoren er kopiert.", "Não há nenhuma aplicação instalada para %@. O identificador foi copiado.", "Nu este instalată nicio aplicație pentru %@. Identificatorul a fost copiat.", "Ingen app är installerad för %@. Identifieraren har kopierats.", "ยังไม่มีแอปที่ติดตั้งสำหรับ %@ คัดลอกตัวระบุแล้ว", "Для %@ не встановлено жодної програми. Ідентифікатор скопійовано.", "Không có ứng dụng nào được cài cho %@. Đã sao chép mã định danh."],

    # --- Cleanup confirmation ----------------------------------------------------
    "cleanup.confirm.titleCount": ["Да се преместят ли %d елемента в Кошчето?", "Přesunout %d položek do Koše?", "Flyt %d elementer til Papirkurven?", "Μετακίνηση %d στοιχείων στον Κάδο;", "¿Mover %d elementos a la Papelera?", "Siirretäänkö %d kohdetta Roskakoriin?", "%d elem áthelyezése a Kukába?", "Pindahkan %d item ke Tempat Sampah?", "Alih %d item ke Tong Sampah?", "Flytte %d elementer til Papirkurven?", "Mover %d itens para o Lixo?", "Muți %d elemente în Coș?", "Flytta %d objekt till Papperskorgen?", "ย้าย %d รายการไปที่ถังขยะหรือไม่", "Перемістити %d елементів у Кошик?", "Chuyển %d mục vào Thùng rác?"],
    "cleanup.confirm.moveAction": ["Преместете в Кошчето", "Přesunout do Koše", "Flyt til Papirkurven", "Μετακίνηση στον Κάδο", "Mover a la Papelera", "Siirrä Roskakoriin", "Áthelyezés a Kukába", "Pindahkan ke Tempat Sampah", "Alih ke Tong Sampah", "Flytt til Papirkurven", "Mover para o Lixo", "Mută în Coș", "Flytta till Papperskorgen", "ย้ายไปที่ถังขยะ", "Перемістити в Кошик", "Chuyển vào Thùng rác"],
    "cleanup.confirm.showItems": ["Прегледайте всеки елемент (%d)", "Projít každou položku (%d)", "Gennemse hvert element (%d)", "Έλεγχος κάθε στοιχείου (%d)", "Revisar cada elemento (%d)", "Tarkista jokainen kohde (%d)", "Minden elem átnézése (%d)", "Tinjau setiap item (%d)", "Semak setiap item (%d)", "Gå gjennom hvert element (%d)", "Rever cada item (%d)", "Verifică fiecare element (%d)", "Granska varje objekt (%d)", "ตรวจสอบแต่ละรายการ (%d)", "Переглянути кожен елемент (%d)", "Xem lại từng mục (%d)"],
    "cleanup.confirm.hideItems": ["Скрийте списъка", "Skrýt seznam", "Skjul listen", "Απόκρυψη λίστας", "Ocultar la lista", "Piilota luettelo", "Lista elrejtése", "Sembunyikan daftar", "Sembunyikan senarai", "Skjul listen", "Ocultar a lista", "Ascunde lista", "Dölj listan", "ซ่อนรายการ", "Сховати список", "Ẩn danh sách"],
    "cleanup.confirm.locations": ["Места", "Místa", "Placeringer", "Τοποθεσίες", "Ubicaciones", "Sijainnit", "Helyek", "Lokasi", "Lokasi", "Steder", "Locais", "Locații", "Platser", "ตำแหน่ง", "Місця", "Vị trí"],
    "cleanup.confirm.protectedCount": ["%d защитени, няма да се преместят", "%d chráněných, nepřesunuto", "%d beskyttede, flyttes ikke", "%d προστατευμένα, δεν μετακινούνται", "%d protegidos, no se moverán", "%d suojattua, ei siirretä", "%d védett, nem kerül áthelyezésre", "%d dilindungi, tidak dipindahkan", "%d dilindungi, tidak dialihkan", "%d beskyttet, flyttes ikke", "%d protegidos, não movidos", "%d protejate, nemutate", "%d skyddade, flyttas inte", "ป้องกันอยู่ %d รายการ ไม่ถูกย้าย", "Захищено %d, не переміщено", "%d mục được bảo vệ, không chuyển"],
    "cleanup.confirm.missingCount": ["%d вече ги няма, пропуснати", "%d už neexistuje, přeskočeno", "%d er allerede væk, sprunget over", "%d έχουν ήδη φύγει, παραλείφθηκαν", "%d ya no están, se omitieron", "%d on jo poistunut, ohitettiin", "%d már nincs meg, kihagyva", "%d sudah tidak ada, dilewati", "%d sudah tiada, dilangkau", "%d er allerede borte, hoppet over", "%d já não existem, ignorados", "%d nu mai există, ignorate", "%d finns inte längre, hoppades över", "หายไปแล้ว %d รายการ ข้ามไป", "%d уже зникли, пропущено", "%d mục đã biến mất, bỏ qua"],
    "cleanup.confirm.reviewCount": ["%d изискват вашето потвърждение", "%d vyžaduje vaše potvrzení", "%d kræver din bekræftelse", "%d χρειάζονται την επιβεβαίωσή σας", "%d necesitan tu revisión", "%d vaatii vahvistuksesi", "%d az Ön megerősítését igényli", "%d perlu ditinjau", "%d perlu anda semak", "%d trenger gjennomgang", "%d precisam de revisão", "%d necesită verificare", "%d behöver granskas", "%d รายการต้องตรวจสอบ", "%d потребують перевірки", "%d mục cần bạn xem lại"],
    "cleanup.confirm.whyRecoverable": ["Защо може да се възстанови", "Proč to lze obnovit", "Hvorfor det kan gendannes", "Γιατί είναι ανακτήσιμο", "Por qué se puede recuperar", "Miksi tämän voi palauttaa", "Miért állítható vissza", "Mengapa ini dapat dipulihkan", "Mengapa boleh dipulihkan", "Hvorfor dette kan gjenopprettes", "Porque é recuperável", "De ce poate fi recuperat", "Varför det kan återställas", "ทำไมจึงกู้คืนได้", "Чому це можна відновити", "Vì sao có thể khôi phục"],

    # --- Cleanup progress and result ---------------------------------------------
    "cleanup.preparing.title": ["Проверка на елементите", "Kontrola položek", "Tjekker elementer", "Έλεγχος στοιχείων", "Comprobando elementos", "Tarkistetaan kohteita", "Elemek ellenőrzése", "Memeriksa item", "Menyemak item", "Sjekker elementer", "A verificar itens", "Se verifică elementele", "Kontrollerar objekt", "กำลังตรวจสอบรายการ", "Перевірка елементів", "Đang kiểm tra mục"],
    "cleanup.executing.title": ["Преместване в Кошчето", "Přesouvání do Koše", "Flytter til Papirkurven", "Μετακίνηση στον Κάδο", "Moviendo a la Papelera", "Siirretään Roskakoriin", "Áthelyezés a Kukába", "Memindahkan ke Tempat Sampah", "Sedang mengalih ke Tong Sampah", "Flytter til Papirkurven", "A mover para o Lixo", "Se mută în Coș", "Flyttar till Papperskorgen", "กำลังย้ายไปที่ถังขยะ", "Переміщення в Кошик", "Đang chuyển vào Thùng rác"],
    "cleanup.executing.progress": ["%d от %d", "%d z %d", "%d af %d", "%d από %d", "%d de %d", "%d / %d", "%d / %d", "%d dari %d", "%d daripada %d", "%d av %d", "%d de %d", "%d din %d", "%d av %d", "%d จาก %d", "%d із %d", "%d trên %d"],
    "cleanup.result.reclaimAfterEmpty": ["Свободното място се увеличава с %@, след като изпразните Кошчето", "Volné místo se zvětší o %@, až koš vysypete", "Ledig plads vokser med %@, når du tømmer Papirkurven", "Ο διαθέσιμος χώρος αυξάνεται κατά %@ μόλις αδειάσετε τον Κάδο", "El espacio disponible aumenta %@ cuando vacías la Papelera", "Vapaa tila kasvaa %@, kun tyhjennät Roskakorin", "A szabad hely %@-kal nő, ha kiüríti a Kukát", "Ruang tersedia bertambah %@ setelah Anda mengosongkan Tempat Sampah", "Ruang tersedia bertambah %@ selepas anda mengosongkan Tong Sampah", "Ledig plass øker med %@ når du tømmer Papirkurven", "O espaço disponível aumenta %@ depois de esvaziar o Lixo", "Spațiul disponibil crește cu %@ după ce golești Coșul", "Ledigt utrymme ökar med %@ när du tömmer Papperskorgen", "พื้นที่ว่างจะเพิ่มขึ้น %@ หลังล้างถังขยะ", "Вільне місце збільшиться на %@, щойно ви спорожните Кошик", "Dung lượng trống tăng thêm %@ sau khi bạn làm trống Thùng rác"],
    "cleanup.result.retryCount": ["Опитайте отново (%d)", "Zkusit znovu (%d)", "Prøv igen (%d)", "Επανάληψη (%d)", "Reintentar (%d)", "Yritä uudelleen (%d)", "Újrapróbálás (%d)", "Coba lagi (%d)", "Cuba lagi %d", "Prøv de %d igjen", "Tentar novamente %d", "Reîncearcă %d", "Försök igen med %d", "ลองอีกครั้ง %d", "Повторити %d", "Thử lại %d"],
    "cleanup.result.undoAction": ["Отменете това почистване", "Vrátit toto čištění", "Fortryd denne oprydning", "Αναίρεση αυτού του καθαρισμού", "Deshacer esta limpieza", "Kumoa tämä siivous", "A tisztítás visszavonása", "Urungkan pembersihan ini", "Buat asal pembersihan ini", "Angre denne oppryddingen", "Anular esta limpeza", "Anulează această curățare", "Ångra den här rensningen", "ย้อนกลับการทำความสะอาดครั้งนี้", "Скасувати це очищення", "Hoàn tác lần dọn dẹp này"],
    "cleanup.result.undoUnavailable": ["Не може да се отмени: Кошчето е изпразнено или елементът е на друг диск", "Nelze vrátit: koš byl vysypán nebo je položka na jiném disku", "Kan ikke fortrydes: Papirkurven er tømt, eller elementet ligger på en anden disk", "Δεν είναι δυνατή η αναίρεση: ο Κάδος άδειασε ή το στοιχείο βρίσκεται σε άλλο δίσκο", "No se puede deshacer: la Papelera se vació o el elemento está en otro disco", "Ei voi kumota: Roskakori on tyhjennetty tai kohde on toisella levyllä", "Nem vonható vissza: a Kuka kiürült, vagy az elem másik lemezen van", "Tidak dapat diurungkan: Tempat Sampah telah dikosongkan atau item berada di disk lain", "Tidak boleh dibuat asal: Tong Sampah telah dikosongkan atau item berada pada cakera lain", "Kan ikke angre: Papirkurven er tømt, eller elementet ligger på en annen disk", "Não é possível anular: o Lixo foi esvaziado ou o item está noutro disco", "Nu se poate anula: Coșul a fost golit sau elementul este pe alt disc", "Går inte att ångra: Papperskorgen har tömts eller så ligger objektet på en annan disk", "ย้อนกลับไม่ได้: ถังขยะถูกล้างแล้ว หรือรายการอยู่บนดิสก์อื่น", "Скасувати неможливо: Кошик спорожнено або елемент на іншому диску", "Không thể hoàn tác: Thùng rác đã được làm trống hoặc mục nằm trên đĩa khác"],
    "cleanup.result.stopped": ["Спряно след %d елемента", "Zastaveno po %d položkách", "Stoppet efter %d elementer", "Σταμάτησε μετά από %d στοιχεία", "Se detuvo después de %d elementos", "Pysäytetty %d kohteen jälkeen", "%d elem után leállítva", "Dihentikan setelah %d item", "Dihentikan selepas %d item", "Stoppet etter %d elementer", "Parou após %d itens", "Oprit după %d elemente", "Stoppades efter %d objekt", "หยุดหลัง %d รายการ", "Зупинено після %d елементів", "Đã dừng sau %d mục"],

    # --- Scan state --------------------------------------------------------------
    "scan.stopped.title": ["Сканирането е спряно", "Skenování zastaveno", "Scanning stoppet", "Η σάρωση σταμάτησε", "Análisis detenido", "Skannaus pysäytetty", "Vizsgálat leállítva", "Pemindaian dihentikan", "Imbasan dihentikan", "Skanning stoppet", "Verificação parada", "Scanare oprită", "Skanningen stoppades", "หยุดการสแกนแล้ว", "Сканування зупинено", "Đã dừng quét"],
    "scan.stopped.detail": ["Преди да спрете бяха намерени %d елемента (%@). Все още можете да ги почистите.", "Než jste skenování zastavili, našlo se %d položek (%@). Stále je můžete vyčistit.", "%d elementer (%@) blev fundet, før du stoppede. Du kan stadig rydde dem.", "Βρέθηκαν %d στοιχεία (%@) πριν σταματήσετε. Μπορείτε ακόμη να τα καθαρίσετε.", "Se encontraron %d elementos (%@) antes de que detuvieras el análisis. Aún puedes limpiarlos.", "Ennen pysäytystä löytyi %d kohdetta (%@). Voit silti siivota ne.", "%d elem (%@) található a leállítás előtt. Még mindig megtisztíthatja őket.", "%d item (%@) ditemukan sebelum Anda menghentikan. Anda tetap dapat membersihkannya.", "%d item (%@) ditemui sebelum anda menghentikannya. Anda masih boleh membersihkannya.", "%d elementer (%@) ble funnet før du stoppet. Du kan fortsatt rydde dem.", "Foram encontrados %d itens (%@) antes de parar. Ainda os pode limpar.", "S-au găsit %d elemente (%@) înainte de a opri. Le poți curăța în continuare.", "%d objekt (%@) hittades innan du stoppade. Du kan fortfarande rensa dem.", "พบ %d รายการ (%@) ก่อนที่คุณจะหยุด คุณยังล้างได้อยู่", "До зупинки знайдено %d елементів (%@). Ви все ще можете їх очистити.", "Đã tìm thấy %d mục (%@) trước khi bạn dừng. Bạn vẫn có thể dọn chúng."],
    "scan.stopping": ["Спиране…", "Zastavování…", "Stopper…", "Γίνεται διακοπή…", "Deteniendo…", "Pysäytetään…", "Leállítás…", "Menghentikan…", "Menghentikan…", "Stopper…", "A parar…", "Se oprește…", "Stoppar…", "กำลังหยุด…", "Зупинка…", "Đang dừng…"],
    "scan.hiddenSelected": ["%d избрани елемента не се показват тук", "%d vybraných položek se zde nezobrazuje", "%d valgte elementer vises ikke her", "%d επιλεγμένα στοιχεία δεν εμφανίζονται εδώ", "%d elementos seleccionados no se muestran aquí", "%d valittua kohdetta ei näytetä tässä", "%d kijelölt elem nem jelenik meg itt", "%d item terpilih tidak ditampilkan di sini", "%d item dipilih tidak dipaparkan di sini", "%d valgte elementer vises ikke her", "%d itens selecionados não são mostrados aqui", "%d elemente selectate nu sunt afișate aici", "%d markerade objekt visas inte här", "มี %d รายการที่เลือกไว้ไม่แสดงที่นี่", "%d вибраних елементів тут не показано", "%d mục đã chọn không hiển thị ở đây"],
    "scan.nothingFoundScope": ["В този обхват няма нищо", "V tomto rozsahu nic není", "Intet i dette område", "Τίποτα σε αυτό το εύρος", "No hay nada en este alcance", "Ei mitään tässä laajuudessa", "Nincs semmi ebben a hatókörben", "Tidak ada apa pun dalam cakupan ini", "Tiada apa-apa dalam skop ini", "Ingenting i dette området", "Nada neste âmbito", "Nimic în acest domeniu", "Inget i det här omfånget", "ไม่มีอะไรในขอบเขตนี้", "У цьому обсязі нічого немає", "Không có gì trong phạm vi này"],

    # --- File cleanup empty states -----------------------------------------------
    "files.noDuplicatesDetail": ["Не са намерени дублирани файлове в папките, които Sift сканира.", "Ve složkách, které Sift proskenoval, nejsou žádné duplicitní soubory.", "Ingen dublerede filer i de mapper, Sift scannede.", "Δεν υπάρχουν διπλότυπα αρχεία στους φακέλους που σάρωσε το Sift.", "No hay archivos duplicados en las carpetas que analizó Sift.", "Siftin skannaamissa kansioissa ei ole kaksoiskappaleita.", "Nincsenek duplikált fájlok a Sift által vizsgált mappákban.", "Tidak ada file duplikat di folder yang dipindai Sift.", "Tiada fail pendua dalam folder yang diimbas oleh Sift.", "Ingen duplikatfiler i mappene Sift skannet.", "Nenhum ficheiro duplicado nas pastas verificadas pelo Sift.", "Niciun fișier duplicat în folderele scanate de Sift.", "Inga dubblettfiler i mapparna Sift skannade.", "ไม่พบไฟล์ซ้ำในโฟลเดอร์ที่ Sift สแกน", "У папках, які сканував Sift, дублікатів немає.", "Không có tệp trùng trong các thư mục Sift đã quét."],

    # --- Full Disk Access and scan scope -----------------------------------------
    "permission.askTitle": ["Да позволи ли на Sift да прочете още малко?", "Nechat Sift nahlédnout o něco víc?", "Skal Sift må se lidt mere?", "Να επιτρέψουμε στο Sift να δει λίγο περισσότερα;", "¿Dejamos que Sift lea un poco más?", "Saako Sift katsoa hieman enemmän?", "Hagyja, hogy a Sift egy kicsit többet lásson?", "Izinkan Sift membaca sedikit lebih banyak?", "Benarkan Sift membaca sedikit lagi?", "La Sift lese litt mer?", "Deixar o Sift ler um pouco mais?", "Lași Sift să citească puțin mai mult?", "Låt Sift läsa lite mer?", "ให้ Sift อ่านเพิ่มอีกนิดไหม", "Дозволити Sift читати трохи більше?", "Cho Sift đọc thêm một chút?"],
    "permission.whyTitle": ["Защо Пълен достъп до диска", "Proč Úplný přístup k disku", "Hvorfor fuld diskadgang", "Γιατί Πλήρης πρόσβαση στον δίσκο", "Por qué el Acceso total al disco", "Miksi täysi levynkäyttöoikeus", "Miért kell Teljes lemezhozzáférés", "Mengapa Akses Disk Penuh", "Mengapa Akses Cakera Penuh", "Hvorfor full disktilgang", "Porquê o Acesso Total ao Disco", "De ce Acces complet la disc", "Varför fullskivåtkomst", "ทำไมต้องเข้าถึงดิสก์ทั้งหมด", "Навіщо Повний доступ до диска", "Vì sao cần Quyền truy cập Toàn bộ Đĩa"],
    "permission.whyBody": ["Обхваща системни журнали и папки за поддръжка на приложения, които macOS защитава. Всичко останало работи и без него.", "Pokrývá systémové protokoly a složky podpory aplikací, které macOS chrání. Vše ostatní funguje i bez něj.", "Det dækker systemlogfiler og app-supportmapper, som macOS beskytter. Alt andet virker uden.", "Καλύπτει αρχεία καταγραφής συστήματος και φακέλους υποστήριξης εφαρμογών, τους οποίους προστατεύει το macOS. Όλα τα άλλα λειτουργούν και χωρίς αυτή.", "Cubre los registros del sistema y las carpetas de soporte de apps, que macOS protege. Todo lo demás funciona sin él.", "Se kattaa järjestelmän lokit ja sovellusten tukikansiot, joita macOS suojaa. Kaikki muu toimii ilman sitä.", "A rendszernaplókat és az alkalmazástámogató mappákat fedi le, amelyeket a macOS véd. Minden más működik nélküle.", "Ini mencakup log sistem dan folder dukungan aplikasi yang dilindungi macOS. Semua fitur lain berfungsi tanpanya.", "Ia meliputi log sistem dan folder sokongan apl, yang dilindungi oleh macOS. Semua yang lain berfungsi tanpanya.", "Den dekker systemloggfiler og appstøttemapper, som macOS beskytter. Alt annet fungerer uten den.", "Abrange os registos do sistema e as pastas de suporte das aplicações, que o macOS protege. Tudo o resto funciona sem ele.", "Acoperă jurnalele de sistem și folderele de suport ale aplicațiilor, pe care macOS le protejează. Restul funcționează fără el.", "Den omfattar systemloggar och appsupportmappar, som macOS skyddar. Allt annat fungerar utan den.", "สิทธิ์นี้ครอบคลุมบันทึกของระบบและโฟลเดอร์สนับสนุนแอปที่ macOS ป้องกันไว้ ส่วนอื่นทำงานได้โดยไม่ต้องใช้สิทธิ์นี้", "Він охоплює системні журнали й папки підтримки програм, які захищає macOS. Усе інше працює й без нього.", "Quyền này bao gồm nhật ký hệ thống và thư mục hỗ trợ ứng dụng do macOS bảo vệ. Mọi thứ khác vẫn hoạt động nếu không có quyền này."],
    "permission.whyRevoke": ["Можете да го изключите по всяко време в Системни настройки → Поверителност и сигурност.", "Vypnout ho můžete kdykoli v Nastavení systému → Soukromí a zabezpečení.", "Du kan slå det fra i Systemindstillinger → Anonymitet og sikkerhed når som helst.", "Μπορείτε να την απενεργοποιήσετε οποιαδήποτε στιγμή στις Ρυθμίσεις συστήματος → Απόρρητο και ασφάλεια.", "Puedes desactivarlo cuando quieras en Ajustes del Sistema → Privacidad y seguridad.", "Voit poistaa sen käytöstä milloin tahansa kohdassa Järjestelmäasetukset → Tietosuoja ja turvallisuus.", "Bármikor kikapcsolhatja a Rendszerbeállítások → Adatvédelem és biztonság alatt.", "Anda dapat mematikannya kapan saja di Pengaturan Sistem → Privasi & Keamanan.", "Anda boleh mematikannya dalam Tetapan Sistem → Privasi & Keselamatan pada bila-bila masa.", "Du kan slå den av i Systeminnstillinger → Personvern og sikkerhet når som helst.", "Pode desativá-lo em Definições do Sistema → Privacidade e Segurança a qualquer momento.", "Îl poți dezactiva oricând în Configurările sistemului → Confidențialitate și securitate.", "Du kan stänga av den i Systeminställningar → Integritet och säkerhet när som helst.", "ปิดได้ทุกเมื่อในการตั้งค่าระบบ → ความเป็นส่วนตัวและความปลอดภัย", "Вимкнути його можна будь-коли в Системних налаштуваннях → Конфіденційність і безпека.", "Bạn có thể tắt quyền này bất cứ lúc nào trong Cài đặt Hệ thống → Quyền riêng tư và Bảo mật."],
    "permission.openedSettings": ["Системни настройки е отворен. Върнете се и сканирайте отново.", "Nastavení systému je otevřené. Vraťte se a skenujte znovu.", "Systemindstillinger er åbne. Kom tilbage, og scan igen.", "Οι Ρυθμίσεις συστήματος είναι ανοιχτές. Επιστρέψτε και σαρώστε ξανά.", "Ajustes del Sistema está abierto. Vuelve y analiza otra vez.", "Järjestelmäasetukset ovat auki. Palaa takaisin ja skannaa uudelleen.", "A Rendszerbeállítások meg van nyitva. Térjen vissza, és vizsgáljon újra.", "Pengaturan Sistem sudah terbuka. Kembali dan pindai lagi.", "Tetapan Sistem telah dibuka. Kembali dan imbas semula.", "Systeminnstillinger er åpnet. Kom tilbake og skann på nytt.", "As Definições do Sistema estão abertas. Volte e verifique novamente.", "Configurările sistemului sunt deschise. Revino și scanează din nou.", "Systeminställningar är öppna. Kom tillbaka och skanna igen.", "เปิดการตั้งค่าระบบแล้ว กลับมาแล้วสแกนอีกครั้ง", "Системні налаштування відкрито. Поверніться й скануйте знову.", "Cài đặt Hệ thống đã mở. Hãy quay lại và quét lại."],
    "permission.protectedTitle": ["Защитено от Sift", "Chráněno Siftem", "Beskyttet af Sift", "Προστατευμένο από το Sift", "Protegido por Sift", "Siftin suojaama", "A Sift által védett", "Dilindungi oleh Sift", "Dilindungi oleh Sift", "Beskyttet av Sift", "Protegido pelo Sift", "Protejat de Sift", "Skyddat av Sift", "Sift ป้องกันไว้", "Захищено Sift", "Được Sift bảo vệ"],
    "permission.systemProtectedTitle": ["Папки, затворени от macOS", "Umístění, která macOS uzavírá", "Placeringer, som macOS holder lukket", "Θέσεις που το macOS κρατά κλειστές", "Ubicaciones cerradas por macOS", "macOS:n sulkemina pitämät sijainnit", "A macOS által zárt helyek", "Lokasi yang ditutup oleh macOS", "Lokasi yang ditutup oleh macOS", "Plasseringer macOS holder lukket", "Localizações fechadas pelo macOS", "Locații închise de macOS", "Platser som macOS håller stängda", "ตำแหน่งที่ macOS ปิดไว้", "Папки, закриті в macOS", "Vị trí macOS giữ kín"],
    "permission.restartHint": ["Ако „Пълен достъп до диска“ вече е включен, затворете Sift и го отворете отново — macOS прилага разрешението при стартиране на приложението.", "Pokud je Úplný přístup k disku už zapnutý, ukončete Sift a znovu ho otevřete — macOS uplatní oprávnění při spuštění aplikace.", "Hvis Fuld diskadgang allerede er slået til, luk Sift og åbn det igen — macOS anvender tilladelsen, når en app starter.", "Αν η Πλήρης πρόσβαση στον δίσκο είναι ήδη ενεργή, κλείστε το Sift και ανοίξτε το ξανά — το macOS εφαρμόζει την άδεια όταν ξεκινά μια εφαρμογή.", "Si el acceso al disco completo ya está activado, cierra Sift y vuelve a abrirlo: macOS aplica el permiso al iniciar la app.", "Jos Täysi levynkäyttöoikeus on jo päällä, sulje Sift ja avaa se uudelleen — macOS ottaa oikeuden käyttöön sovelluksen käynnistyessä.", "Ha a Teljes lemezhozzáférés már be van kapcsolva, lépjen ki a Siftből, és nyissa meg újra — a macOS az engedélyt az app indításakor alkalmazza.", "Jika Akses Disk Penuh sudah aktif, tutup Sift lalu buka lagi — macOS menerapkan izin saat app dimulai.", "Jika Akses Penuh Cakera sudah dihidupkan, keluar dari Sift dan buka semula — macOS menggunakan kebenaran itu apabila app dimulakan.", "Hvis Full diskadgang allerede er på, avslutt Sift og åpne det igjen — macOS bruker tillatelsen når en app starter.", "Se o Acesso Total ao Disco já estiver ativo, feche o Sift e volte a abri-lo — o macOS aplica a permissão quando a app inicia.", "Dacă Accesul complet la disc este deja activ, închideți Sift și redeschideți-l — macOS aplică permisiunea la pornirea aplicației.", "Om Fullskivåtkomst redan är på, avsluta Sift och öppna det igen — macOS tillämpar behörigheten när en app startar.", "ถ้าเปิดการเข้าถึงดิสก์เต็มรูปแบบไว้แล้ว ให้ออกจาก Sift แล้วเปิดใหม่ — macOS จะใช้สิทธิ์เมื่อแอปเริ่มทำงาน", "Якщо «Повний доступ до диска» вже ввімкнено, закрийте Sift і відкрийте його знову — macOS застосовує дозвіл під час запуску програми.", "Nếu Quyền truy cập toàn bộ ổ đĩa đã bật, hãy thoát Sift rồi mở lại — macOS áp dụng quyền này khi ứng dụng khởi động."],
    "scan.skippedReason.systemRestricted": ["Тази папка принадлежи на macOS или на друг потребител, затова Sift не може да я прочете.", "Toto umístění patří macOS nebo jinému uživateli, takže je Sift nemůže přečíst.", "Denne placering tilhører macOS eller en anden bruger, så Sift kan ikke læse den.", "Αυτή η θέση ανήκει στο macOS ή σε άλλον χρήστη, οπότε το Sift δεν μπορεί να τη διαβάσει.", "Esta ubicación pertenece a macOS o a otro usuario, así que Sift no puede leerla.", "Tämä sijainti kuuluu macOS:lle tai toiselle käyttäjälle, joten Sift ei voi lukea sitä.", "Ez a hely a macOS vagy egy másik felhasználó tulajdona, ezért a Sift nem tudja beolvasni.", "Lokasi ini milik macOS atau pengguna lain, jadi Sift tidak dapat membacanya.", "Lokasi ini dimiliki oleh macOS atau pengguna lain, jadi Sift tidak dapat membacanya.", "Denne plasseringen tilhører macOS eller en annen bruker, så Sift kan ikke lese den.", "Esta localização pertence ao macOS ou a outro utilizador, por isso o Sift não a consegue ler.", "Această locație aparține macOS sau altui utilizator, așa că Sift nu o poate citi.", "Den här platsen tillhör macOS eller en annan användare, så Sift kan inte läsa den.", "ตำแหน่งนี้เป็นของ macOS หรือผู้ใช้อื่น Sift จึงอ่านไม่ได้", "Ця папка належить macOS або іншому користувачу, тому Sift не може її прочитати.", "Vị trí này thuộc về macOS hoặc người dùng khác, nên Sift không thể đọc được."],
    "scan.firstRun.scope": ["Sift чете кешове, журнали и инсталатори в тези места:", "Sift čte mezipaměti, protokoly a instalátory na těchto místech:", "Sift læser caches, logfiler og installationsprogrammer på disse placeringer:", "Το Sift διαβάζει cache, αρχεία καταγραφής και προγράμματα εγκατάστασης σε αυτές τις τοποθεσίες:", "Sift lee cachés, registros e instaladores en estas ubicaciones:", "Sift lukee välimuisteja, lokeja ja asennusohjelmia näistä sijainneista:", "A Sift gyorsítótárakat, naplókat és telepítőket olvas ezeken a helyeken:", "Sift membaca cache, log, dan penginstal di lokasi berikut:", "Sift membaca cache, log dan pemasang di lokasi ini:", "Sift leser cacher, loggfiler og installasjonsprogrammer på disse stedene:", "O Sift lê caches, registos e instaladores nestes locais:", "Sift citește cache-uri, jurnale și instalatoare în aceste locații:", "Sift läser cacher, loggar och installationsprogram på de här platserna:", "Sift อ่านแคช บันทึก และไฟล์ติดตั้งในตำแหน่งเหล่านี้", "Sift читає кеші, журнали й інсталятори в цих місцях:", "Sift đọc bộ nhớ đệm, nhật ký và bộ cài ở những vị trí sau:"],
    "scan.scopeNote": ["Чете само имена, размери и дати · пълният обхват изисква Пълен достъп до диска", "Čte jen názvy, velikosti a data · plné pokrytí vyžaduje Úplný přístup k disku", "Læser kun navne, størrelser og datoer · fuld dækning kræver fuld diskadgang", "Διαβάζει μόνο ονόματα, μεγέθη και ημερομηνίες · η πλήρης κάλυψη απαιτεί Πλήρη πρόσβαση στον δίσκο", "Solo lee nombres, tamaños y fechas · la cobertura completa necesita Acceso total al disco", "Lukee vain nimet, koot ja päivämäärät · täysi kattavuus vaatii täyden levynkäyttöoikeuden", "Csak neveket, méreteket és dátumokat olvas · a teljes lefedettséghez Teljes lemezhozzáférés kell", "Hanya membaca nama, ukuran, dan tanggal · cakupan penuh memerlukan Akses Disk Penuh", "Hanya membaca nama, saiz dan tarikh · liputan penuh memerlukan Akses Cakera Penuh", "Leser bare navn, størrelser og datoer · full dekning krever full disktilgang", "Lê apenas nomes, tamanhos e datas · a cobertura completa requer Acesso Total ao Disco", "Citește doar nume, dimensiuni și date · acoperirea completă necesită Acces complet la disc", "Läser bara namn, storlekar och datum · full täckning kräver fullskivåtkomst", "อ่านเฉพาะชื่อ ขนาด และวันที่ · ต้องใช้การเข้าถึงดิสก์ทั้งหมดเพื่อครอบคลุมทั้งหมด", "Читаються лише назви, розміри й дати · повне охоплення потребує Повного доступу до диска", "Chỉ đọc tên, kích thước và ngày · phạm vi đầy đủ cần Quyền truy cập Toàn bộ Đĩa"],

    # --- Purchase, settings and navigation ---------------------------------------
    "purchase.activate": ["Активирайте лицензионен ключ", "Aktivovat licenční klíč", "Aktivér en licensnøgle", "Ενεργοποίηση κλειδιού άδειας", "Activar una clave de licencia", "Aktivoi lisenssiavain", "Licenckulcs aktiválása", "Aktifkan kunci lisensi", "Aktifkan kunci lesen", "Aktiver en lisensnøkkel", "Ativar uma chave de licença", "Activează o cheie de licență", "Aktivera en licensnyckel", "เปิดใช้งานคีย์ลิขสิทธิ์", "Активувати ліцензійний ключ", "Kích hoạt khóa giấy phép"],
    "purchase.openStore": ["Купете от уебсайта", "Koupit na webu", "Køb på webstedet", "Αγορά από τον ιστότοπο", "Comprar en el sitio web", "Osta verkkosivustolta", "Vásárlás a weboldalon", "Beli di situs web", "Beli di laman web", "Kjøp på nettstedet", "Comprar no site", "Cumpără de pe site", "Köp på webbplatsen", "ซื้อบนเว็บไซต์", "Купити на вебсайті", "Mua trên trang web"],
    "purchase.unavailable": ["Покупката в приложението не е достъпна в тази версия.", "Nákup v aplikaci není v této verzi dostupný.", "Køb i appen er ikke tilgængeligt i denne version.", "Η αγορά εντός εφαρμογής δεν είναι διαθέσιμη σε αυτή την έκδοση.", "La compra dentro de la app no está disponible en esta versión.", "Sovelluksen sisäinen osto ei ole käytettävissä tässä versiossa.", "Az alkalmazáson belüli vásárlás nem érhető el ebben a verzióban.", "Pembelian dalam aplikasi tidak tersedia di versi ini.", "Pembelian dalam apl tidak tersedia dalam binaan ini.", "Kjøp i appen er ikke tilgjengelig i denne versjonen.", "A compra na aplicação não está disponível nesta versão.", "Achiziția din aplicație nu este disponibilă în această versiune.", "Köp i appen är inte tillgängligt i den här versionen.", "การซื้อในแอปไม่มีในเวอร์ชันนี้", "Покупка в програмі недоступна в цій збірці.", "Tính năng mua trong ứng dụng không có trong bản dựng này."],
    "settings.showConfirmList": ["Показвайте списъка с елементи преди почистване", "Před čištěním zobrazit seznam položek", "Vis elementlisten før oprydning", "Εμφάνιση λίστας στοιχείων πριν από τον καθαρισμό", "Mostrar la lista de elementos antes de limpiar", "Näytä kohdeluettelo ennen siivousta", "Elemlista megjelenítése tisztítás előtt", "Tampilkan daftar item sebelum membersihkan", "Tunjukkan senarai item sebelum membersihkan", "Vis elementlisten før opprydding", "Mostrar a lista de itens antes de limpar", "Arată lista de elemente înainte de curățare", "Visa objektlistan innan rensning", "แสดงรายการก่อนทำความสะอาด", "Показувати список елементів перед очищенням", "Hiện danh sách mục trước khi dọn dẹp"],
    "settings.showConfirmListWarning": ["Изключването премахва последната проверка. Елементите все още отиват в Кошчето, но няма да виждате какво се мести.", "Vypnutím zmizí poslední kontrola. Položky stále jdou do Koše, ale neuvidíte, co se přesouvá.", "Slår du det fra, fjernes det sidste tjek. Elementerne ryger stadig i Papirkurven, men du ser ikke, hvad der flyttes.", "Αν το απενεργοποιήσετε, αφαιρείται ο τελευταίος έλεγχος. Τα στοιχεία πηγαίνουν πάντα στον Κάδο, αλλά δεν θα βλέπετε τι μετακινείται.", "Si lo desactivas, se elimina la última verificación. Los elementos siguen yendo a la Papelera, pero no verás qué se mueve.", "Tämän poistaminen käytöstä poistaa viimeisen tarkistuksen. Kohteet siirtyvät silti Roskakoriin, mutta et näe, mitä siirtyy.", "Ha kikapcsolja, eltűnik az utolsó ellenőrzés. Az elemek továbbra is a Kukába kerülnek, de nem látja, mi kerül át.", "Jika dimatikan, pemeriksaan terakhir akan hilang. Item tetap dipindahkan ke Tempat Sampah, tetapi Anda tidak akan melihat apa yang dipindahkan.", "Mematikannya akan menghapuskan titik semak terakhir. Item tetap masuk ke Tong Sampah, tetapi anda tidak akan melihat apa yang dialihkan.", "Slår du dette av, forsvinner den siste kontrollen. Elementene går fortsatt til Papirkurven, men du ser ikke hva som flyttes.", "Desativar esta opção remove a última verificação. Os itens continuam a ir para o Lixo, mas não verá o que é movido.", "Dacă dezactivezi această opțiune, dispare ultima verificare. Elementele ajung tot în Coș, dar nu vei vedea ce se mută.", "Stänger du av det här försvinner den sista kontrollen. Objekten hamnar fortfarande i Papperskorgen, men du ser inte vad som flyttas.", "การปิดตัวเลือกนี้จะตัดจุดตรวจสอบสุดท้ายออก รายการยังถูกย้ายไปที่ถังขยะ แต่คุณจะไม่เห็นว่าอะไรถูกย้าย", "Якщо вимкнути це, зникне остання перевірка. Елементи все одно перейдуть у Кошик, але ви не побачите, що саме переміщується.", "Tắt tùy chọn này sẽ bỏ mất bước kiểm tra cuối. Các mục vẫn được chuyển vào Thùng rác nhưng bạn sẽ không thấy mục nào bị chuyển."],
    "settings.includeHidden": ["Включете скрити файлове в сканиранията", "Zahrnout skryté soubory do skenování", "Medtag skjulte filer i scanninger", "Συμπερίληψη κρυφών αρχείων στις σαρώσεις", "Incluir archivos ocultos en los análisis", "Sisällytä piilotetut tiedostot skannauksiin", "Rejtett fájlok felvétele a vizsgálatokba", "Sertakan file tersembunyi dalam pemindaian", "Sertakan fail tersembunyi dalam imbasan", "Ta med skjulte filer i skanninger", "Incluir ficheiros ocultos nas verificações", "Include fișierele ascunse în scanări", "Inkludera dolda filer i skanningar", "รวมไฟล์ที่ซ่อนอยู่ในการสแกน", "Включати приховані файли до сканувань", "Bao gồm tệp ẩn khi quét"],
    "trash.emptyConfirmAction": ["Изтрийте за постоянно", "Trvale smazat", "Slet permanent", "Οριστική διαγραφή", "Eliminar permanentemente", "Poista pysyvästi", "Végleges törlés", "Hapus permanen", "Padam secara kekal", "Slett permanent", "Eliminar permanentemente", "Șterge definitiv", "Radera permanent", "ลบอย่างถาวร", "Видалити остаточно", "Xóa vĩnh viễn"],
    "common.copyReason": ["Копиране на причината", "Kopírovat důvod", "Kopiér årsag", "Αντιγραφή αιτίας", "Copiar motivo", "Kopioi syy", "Ok másolása", "Salin alasan", "Salin sebab", "Kopier årsak", "Copiar motivo", "Copiază motivul", "Kopiera orsak", "คัดลอกเหตุผล", "Копіювати причину", "Sao chép lý do"],
    "common.stop": ["Спрете", "Zastavit", "Stop", "Διακοπή", "Detener", "Pysäytä", "Leállítás", "Hentikan", "Hentikan", "Stopp", "Parar", "Oprește", "Stoppa", "หยุด", "Зупинити", "Dừng"],
    "cleanup.busyNotice": ["Друга операция още тече. Опитайте отново след малко.", "Probíhá jiná operace. Zkuste to znovu za chvíli.", "En anden handling kører stadig. Prøv igen om lidt.", "Μια άλλη ενέργεια εκτελείται ακόμη. Δοκιμάστε ξανά σε λίγο.", "Hay otra operación en curso. Vuelve a intentarlo en un momento.", "Toinen toiminto on vielä käynnissä. Yritä hetken kuluttua uudelleen.", "Egy másik művelet még fut. Próbálja újra egy pillanat múlva.", "Operasi lain masih berjalan. Coba lagi sebentar.", "Operasi lain masih berjalan. Cuba lagi sebentar.", "En annen handling pågår fortsatt. Prøv igjen om litt.", "Outra operação ainda está a decorrer. Tente novamente dentro de momentos.", "Altă operație este încă în curs. Încearcă din nou într-o clipă.", "En annan åtgärd pågår fortfarande. Försök igen om en stund.", "ยังมีอีกการทำงานหนึ่งค้างอยู่ ลองอีกครั้งในอีกสักครู่", "Інша операція ще виконується. Спробуйте ще раз за мить.", "Một thao tác khác vẫn đang chạy. Hãy thử lại sau giây lát."],
    "cleanup.nothingToDo": ["В момента нищо от избраното не може да бъде преместено.", "Nic z výběru teď nelze přesunout.", "Intet i markeringen kan flyttes lige nu.", "Αυτή τη στιγμή δεν μπορεί να μετακινηθεί τίποτα από την επιλογή.", "Ahora no se puede mover nada de lo seleccionado.", "Valinnasta ei voi juuri nyt siirtää mitään.", "Most semmi sem helyezhető át a kijelölésből.", "Tidak ada yang bisa dipindahkan dari pilihan ini sekarang.", "Tiada apa dalam pilihan ini boleh dialihkan sekarang.", "Ingenting i utvalget kan flyttes akkurat nå.", "Nada da seleção pode ser movido agora.", "Nimic din selecție nu poate fi mutat acum.", "Inget i markeringen kan flyttas just nu.", "ตอนนี้ยังย้ายรายการที่เลือกไม่ได้", "Зараз нічого з вибраного перемістити неможливо.", "Hiện không thể di chuyển mục nào trong lựa chọn này."],
    "scan.partialBudget": ["Сканирането приключи по-рано, за да остане приложението отзивчиво — резултатите са частични.", "Skenování skončilo dříve, aby aplikace zůstala plynulá — výsledky jsou částečné.", "Scanningen stoppede tidligt for at holde appen flydende — resultaterne er delvise.", "Η σάρωση σταμάτησε νωρίτερα για να μένει η εφαρμογή αποκρίσιμη — τα αποτελέσματα είναι μερικά.", "El análisis terminó antes para mantener la fluidez: los resultados son parciales.", "Skannaus päättyi aikaisin, jotta sovellus pysyy sulavana — tulokset ovat osittaisia.", "A vizsgálat korábban ért véget, hogy az alkalmazás folyamatos maradjon — az eredmény részleges.", "Pemindaian berhenti lebih awal agar aplikasi tetap responsif — hasilnya sebagian.", "Imbasan berhenti lebih awal agar apl kekal lancar — hasilnya separa.", "Skanningen stoppet tidlig for at appen skal forbli smidig — resultatene er delvise.", "A verificação parou mais cedo para manter a fluidez — os resultados são parciais.", "Scanarea s-a oprit mai devreme pentru ca aplicația să rămână fluidă — rezultatele sunt parțiale.", "Skanningen avbröts tidigt för att appen ska förbli smidig — resultatet är delvis.", "การสแกนหยุดเร็วขึ้นเพื่อให้แอปยังลื่นไหล ผลลัพธ์จึงไม่ครบถ้วน", "Сканування завершилося раніше, щоб застосунок залишався чуйним — результати часткові.", "Quá trình quét dừng sớm để ứng dụng luôn mượt — kết quả chỉ là một phần."],
    "settings.ignoreEmpty": ["Още няма изключени папки.", "Zatím žádná vyloučená složka.", "Ingen mapper er udelukket endnu.", "Δεν έχει εξαιρεθεί κανένας φάκελος ακόμη.", "Aún no hay carpetas excluidas.", "Ei vielä yhtään ohitettua kansiota.", "Még nincs kizárt mappa.", "Belum ada folder yang dikecualikan.", "Belum ada folder yang dikecualikan.", "Ingen mapper er utelatt ennå.", "Ainda não há pastas ignoradas.", "Nicio folderă exclusă încă.", "Ingen mapp är undantagen än.", "ยังไม่มีโฟลเดอร์ที่ยกเว้น", "Ще немає виключених папок.", "Chưa có thư mục nào bị bỏ qua."],
    "settings.addFolder": ["Добавяне на папка", "Přidat složku", "Tilføj en mappe", "Προσθήκη φακέλου", "Añadir carpeta", "Lisää kansio", "Mappa hozzáadása", "Tambah folder", "Tambah folder", "Legg til en mappe", "Adicionar uma pasta", "Adaugă un folder", "Lägg till en mapp", "เพิ่มโฟลเดอร์", "Додати папку", "Thêm thư mục"],
    "settings.keepHistory": ["Колко сканирания да се пазят", "Kolik skenování uchovat", "Antal scanninger der gemmes", "Πόσες σαρώσεις να διατηρούνται", "Análisis a conservar", "Säilytettävät skannaukset", "Megtartott vizsgálatok", "Riwayat pemindaian disimpan", "Sejarah imbasan disimpan", "Antall skanninger som lagres", "Verificações a manter", "Scanări de păstrat", "Antal skanningar att spara", "จำนวนประวัติการสแกนที่เก็บ", "Скільки сканувань зберігати", "Số lần quét được lưu"],
    "settings.launchAtLogin": ["Отваряне на Sift при вход", "Otevřít Sift při přihlášení", "Åbn Sift ved login", "Άνοιγμα του Sift κατά τη σύνδεση", "Abrir Sift al iniciar sesión", "Avaa Sift kirjautuessa", "Sift megnyitása bejelentkezéskor", "Buka Sift saat masuk", "Buka Sift semasa log masuk", "Åpne Sift ved pålogging", "Abrir o Sift ao iniciar sessão", "Deschide Sift la autentificare", "Öppna Sift vid inloggning", "เปิด Sift เมื่อเข้าสู่ระบบ", "Відкривати Sift під час входу", "Mở Sift khi đăng nhập"],
    "common.today": ["Днес", "Dnes", "I dag", "Σήμερα", "Hoy", "Tänään", "Ma", "Hari ini", "Hari ini", "I dag", "Hoje", "Astăzi", "I dag", "วันนี้", "Сьогодні", "Hôm nay"],
    "common.yesterday": ["Вчера", "Včera", "I går", "Χθες", "Ayer", "Eilen", "Tegnap", "Kemarin", "Semalam", "I går", "Ontem", "Ieri", "I går", "เมื่อวาน", "Учора", "Hôm qua"],
    "common.daysAgo": ["Преди %d дни", "před %d dny", "For %d dage siden", "πριν από %d ημέρες", "Hace %d días", "%d päivää sitten", "%d napja", "%d hari lalu", "%d hari lalu", "For %d dager siden", "Há %d dias", "acum %d zile", "För %d dagar sedan", "%d วันที่แล้ว", "%d днів тому", "%d ngày trước"],
    "settings.textSize": ["Размер на текста", "Velikost textu", "Tekststørrelse", "Μέγεθος κειμένου", "Tamaño del texto", "Tekstin koko", "Szövegméret", "Ukuran teks", "Saiz teks", "Tekststørrelse", "Tamanho do texto", "Mărimea textului", "Textstorlek", "ขนาดข้อความ", "Розмір тексту", "Cỡ chữ"],
    "settings.textSizeSmall": ["Малък", "Malý", "Lille", "Μικρό", "Pequeño", "Pieni", "Kicsi", "Kecil", "Kecil", "Liten", "Pequeno", "Mic", "Liten", "เล็ก", "Малий", "Nhỏ"],
    "settings.textSizeDefault": ["Стандартен", "Výchozí", "Standard", "Προεπιλογή", "Predeterminado", "Oletus", "Alap", "Standar", "Lalai", "Standard", "Padrão", "Implicit", "Standard", "ค่าเริ่มต้น", "Стандартний", "Mặc định"],
    "settings.textSizeLarge": ["Голям", "Velký", "Stor", "Μεγάλο", "Grande", "Suuri", "Nagy", "Besar", "Besar", "Stor", "Grande", "Mare", "Stor", "ใหญ่", "Великий", "Lớn"],
    "scan.firstRun.review": ["Първо почистване: разгънете списъка преди да потвърдите.", "První čištění: před potvrzením rozbalte seznam.", "Første oprydning: åbn listen, før du bekræfter.", "Πρώτος καθαρισμός: ανοίξτε τη λίστα πριν επιβεβαιώσετε.", "Primera limpieza: abre la lista antes de confirmar.", "Ensimmäinen siivous: avaa luettelo ennen vahvistusta.", "Első tisztítás: a megerősítés előtt nyissa ki a listát.", "Pembersihan pertama: buka daftar sebelum mengonfirmasi.", "Pembersihan pertama: buka senarai sebelum mengesahkan.", "Første opprydding: åpne listen før du bekrefter.", "Primeira limpeza: abra a lista antes de confirmar.", "Prima curățare: deschide lista înainte de a confirma.", "Första rensningen: öppna listan innan du bekräftar.", "การทำความสะอาดครั้งแรก: เปิดรายการก่อนยืนยัน", "Перше очищення: розгорніть список перед підтвердженням.", "Lần dọn dẹp đầu tiên: mở danh sách trước khi xác nhận."],
}

LANGUAGES = LANGUAGES + EXPANSION_3_LANGUAGES

_missing = [key for key in STRINGS if key not in STRINGS_EXPANSION_3]
_extra = [key for key in STRINGS_EXPANSION_3 if key not in STRINGS]
if _missing or _extra:
    raise SystemExit(
        f"the third expansion table is out of step with the v1 table: "
        f"{len(_missing)} missing (first: {_missing[:3]}), "
        f"{len(_extra)} extra (first: {_extra[:3]})"
    )
for _key, _row in STRINGS.items():
    _row.extend(STRINGS_EXPANSION_3[_key])
del _missing, _extra, _key, _row

def build_catalog() -> dict:
    """Builds the String Catalog structure from the table."""
    strings: dict[str, dict] = {}
    for key, values in STRINGS.items():
        if len(values) != len(LANGUAGES):
            raise SystemExit(
                f"key {key!r} has {len(values)} translations, expected {len(LANGUAGES)}"
            )
        localizations: dict[str, dict] = {}
        source_value = values[LANGUAGES.index(SOURCE)]
        for index, language in enumerate(LANGUAGES):
            value = values[index]
            # The source language is recorded without a redundant state marker.
            localizations[language] = {
                "stringUnit": {
                    "state": "translated" if value else "new",
                    "value": value,
                }
            }
        strings[key] = {
            "comment": None,
            "extractionState": "manual",
            "localizations": localizations,
        }
        del source_value

    return {
        "sourceLanguage": SOURCE,
        "strings": dict(sorted(strings.items())),
        "version": "1.0",
    }


def rendered_strings_files() -> dict[str, str]:
    """Renders one `.lproj/Localizable.strings` per language.

    The string catalog is the source of record, and Xcode compiles it. A plain
    SwiftPM build has no `xcstringstool` unless Xcode is installed, so the same
    table is also emitted in the legacy format that every toolchain reads. Both
    outputs come from this one table, so they cannot disagree.
    """
    files: dict[str, str] = {}
    for index, language in enumerate(LANGUAGES):
        lines = [
            f"/* Sift — {language} */",
            "/* Generated by Scripts/generate-strings.py. Do not edit by hand. */",
            "",
        ]
        for key in sorted(STRINGS):
            value = STRINGS[key][index]
            if not value:
                continue
            # Escape the two characters that would break the format.
            escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            lines.append(f'"{key}" = "{escaped}";')
        files[language] = "\n".join(lines) + "\n"
    return files



# --- Plural forms -----------------------------------------------------------
#
# A count rendered with one fixed noun prints "1 items" in every language that
# distinguishes a singular. ICU would solve this, but the build has to produce the
# same strings on a machine with only the Command Line Tools, so the two facts a
# plural needs live here instead: which form a count takes, and what that form
# says.
#
# `PLURAL_RULES` is the whole of the first fact for the shipped languages, and it
# is emitted into Swift by `swift_plural_source()` so the two sides cannot
# disagree. It is deliberately *not* a full CLDR implementation: a language whose
# plural system needs more than a singular is either written in a label form that
# needs no inflection at all (ru/uk/pl/cs "Элементов: %d", ro "Elemente: %d") or
# takes the bare noun after a numeral (tr/ja/zh/ko/vi/th/id/ms/hu). Those are
# listed as `never`, which is a statement, not an omission.
PLURAL_RULES: dict[str, str] = {
    "fr": "atMostOne",
    "en": "exactlyOne", "de": "exactlyOne", "es": "exactlyOne", "es-419": "exactlyOne",
    "it": "exactlyOne", "pt-br": "exactlyOne", "pt-pt": "exactlyOne", "nl": "exactlyOne",
    "da": "exactlyOne", "nb": "exactlyOne", "fi": "exactlyOne", "el": "exactlyOne",
    "he": "exactlyOne", "bg": "exactlyOne", "ar": "exactlyOne",
}

# key -> {language: singular form}. A language that is absent reuses its base
# string, which is the right answer for a language with no singular form and an
# acceptable one for a language whose noun does not inflect.
PLURAL_ONE: dict[str, dict[str, str]] = {
    "common.itemCount": {
        "en": "%d item", "de": "%d Eintrag", "fr": "%d élément", "es": "%d elemento",
        "es-419": "%d elemento", "it": "%d elemento", "pt-br": "%d item",
        "pt-pt": "%d item", "nl": "%d item", "da": "%d element", "nb": "%d element",
        "fi": "%d kohde", "el": "%d στοιχείο", "he": "%d פריט", "bg": "%d елемент",
        "ar": "%d عنصر",
    },
    "common.fileCount": {
        "en": "%d file", "de": "%d Datei", "fr": "%d fichier", "es": "%d archivo",
        "es-419": "%d archivo", "pt-br": "%d arquivo", "pt-pt": "%d ficheiro",
        "nl": "%d bestand", "da": "%d fil", "nb": "%d fil", "fi": "%d tiedosto",
        "el": "%d αρχείο", "he": "%d קובץ", "bg": "%d файл", "ar": "%d ملف",
    },
    "cleanup.result.moved": {
        "en": "%d item moved to Trash",
        "de": "%d Eintrag in den Papierkorb verschoben",
        "fr": "%d élément déplacé vers la corbeille",
        "es": "%d elemento movido a la papelera",
        "es-419": "%d elemento movido a la Papelera",
        "it": "%d elemento spostato nel Cestino",
        "pt-br": "%d item movido para a Lixeira",
        "pt-pt": "%d item movido para o Lixo",
        "nl": "%d item naar de Prullenbak verplaatst",
        "da": "%d element flyttet til Papirkurven",
        "nb": "%d element flyttet til Papirkurven",
        "fi": "%d kohde siirretty Roskakoriin",
        "el": "%d στοιχείο μετακινήθηκε στον Κάδο",
        "he": "%d פריט הועבר אל פח האשפה",
        "bg": "%d елемент преместен в Кошчето",
        "ar": "نُقل %d عنصر إلى المهملات",
    },
}


def expand_plural_rows() -> None:
    """Adds one sibling key per plural string: `<key>.one`.

    A sibling key rather than a `stringsdict`: every toolchain this repository
    builds with reads `Localizable.strings`, the catalog stays one flat table a
    reviewer can read, and the runtime picks the form from the same rule table
    that produced it.
    """
    for key, forms in PLURAL_ONE.items():
        base = STRINGS[key]
        one = []
        for index, language in enumerate(LANGUAGES):
            one.append(forms.get(language, base[index]))
        STRINGS[key + ".one"] = one


def swift_plural_source() -> str:
    lines = [
        "// Generated by Scripts/generate-strings.py. Do not edit by hand.",
        "//",
        "// Which counts take a singular noun, per language. The table is emitted",
        "// from the same Python dict that produced the `<key>.one` strings, so the",
        "// form a count selects and the string it selects cannot drift apart.",
        "import Foundation",
        "",
        "public enum SiftPlural {",
        "    /// The shipped languages, as a statement about each one's plural system.",
        "    public static func takesSingular(language: String, count: Int) -> Bool {",
        "        switch language {",
    ]
    at_most_one = sorted(l for l, rule in PLURAL_RULES.items() if rule == "atMostOne")
    exactly_one = sorted(l for l, rule in PLURAL_RULES.items() if rule == "exactlyOne")
    if at_most_one:
        joined = ", ".join(f'"{l}"' for l in at_most_one)
        lines.append(f"        case {joined}: return count <= 1")
    if exactly_one:
        joined = ", ".join(f'"{l}"' for l in exactly_one)
        lines.append(f"        case {joined}: return count == 1")
    lines += [
        "        default:",
        "            // A label form or a language whose noun does not inflect after a",
        "            // numeral: the base string is already correct for every count.",
        "            return false",
        "        }",
        "    }",
        "}",
        "",
    ]
    return "\n".join(lines)


def swift_case_name(key: str) -> str:
    """`cleanup.explanation.largeFiles` -> `cleanupExplanationLargeFiles`."""
    parts = re.split(r"[^0-9A-Za-z]+", key)
    name = parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])
    if not name or not name[0].isalpha() or not name.isidentifier():
        raise SystemExit(f"{key!r} does not make a Swift identifier")
    return name


def swift_keys_source() -> str:
    cases = "".join(
        f'    case {swift_case_name(key)} = "{key}"\n' for key in sorted(STRINGS)
    )
    return (
        "import Foundation\n"
        "import SwiftUI\n"
        "\n"
        "/// Every user-visible string in the app.\n"
        "///\n"
        "/// Generated by `Scripts/generate-strings.py` from the same table that writes\n"
        "/// `Localizable.xcstrings`: the raw value is the key the catalog uses, and a\n"
        "/// key added there without a case here could never be referenced. Views never\n"
        "/// spell a key inline, so a typo cannot reach a user as a raw identifier.\n"
        "public enum LocalizationKey: String, Sendable, CaseIterable {\n"
        f"{cases}"
        "}\n"
        "\n"
        "extension LocalizationKey {\n"
        "    /// The localised string, resolved against the bundled catalog.\n"
        "    ///\n"
        "    /// Resolution uses the explicitly selected language bundle rather than\n"
        "    /// `LocalizedStringKey`, which would consult the main bundle and ignore this\n"
        "    /// preference. Returning the resolved string allows the UI language to change\n"
        "    /// immediately without requiring an application restart.\n"
        "    ///\n"
        "    /// Missing translations fall back to English, which the catalog records as\n"
        "    /// the source language.\n"
        "    public var localized: String {\n"
        '        Bundle.localizedBundle(for: SiftLanguage.current).localizedString(forKey: rawValue, value: nil, table: "Localizable")\n'
        "    }\n"
        "\n"
        "    /// The localised string with positional arguments substituted.\n"
        "    public func localized(_ arguments: CVarArg...) -> String {\n"
        "        String(format: localized, arguments: arguments)\n"
        "    }\n"
        "}\n"
    )


def main() -> int:
    # The plural forms are sibling keys of the strings they inflect, so they have
    # to exist before anything is rendered or checked.
    expand_plural_rows()
    catalog = build_catalog()
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    rendered_keys = swift_keys_source()
    plural_path = REPO_ROOT / "Shared" / "Localization" / "PluralForms.swift"
    rendered_plurals = swift_plural_source()

    if "--check" in sys.argv:
        current = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
        if current != rendered:
            print("Localizable.xcstrings is out of date; run Scripts/generate-strings.py")
            return 1
        keys_current = KEYS.read_text(encoding="utf-8") if KEYS.exists() else ""
        if keys_current != rendered_keys:
            print("LocalizationKey.swift is out of date; run Scripts/generate-strings.py")
            return 1
        plural_current = plural_path.read_text(encoding="utf-8") if plural_path.exists() else ""
        if plural_current != rendered_plurals:
            print("PluralForms.swift is out of date; run Scripts/generate-strings.py")
            return 1
            return 1
        strings_root = CATALOG.parent / "Compiled"
        for language, content in rendered_strings_files().items():
            path = strings_root / f"{language}.lproj" / "Localizable.strings"
            current_strings = path.read_text(encoding="utf-8") if path.exists() else ""
            if current_strings != content:
                print(f"{path.relative_to(REPO_ROOT)} is out of date; run Scripts/generate-strings.py")
                return 1
        expected_dirs = {f"{language}.lproj" for language in rendered_strings_files()}
        if strings_root.exists():
            extra = sorted(
                entry.name
                for entry in strings_root.iterdir()
                if entry.is_dir() and entry.name not in expected_dirs
            )
            if extra:
                print(f"unexpected .lproj bundles under {strings_root.relative_to(REPO_ROOT)}: {extra}")
                return 1
        print(
            f"Localizable.xcstrings, LocalizationKey.swift and .lproj bundles are current "
            f"({len(STRINGS)} keys, {len(LANGUAGES)} languages)"
        )
        return 0

    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    with CATALOG.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    print(f"wrote {CATALOG.relative_to(REPO_ROOT)} ({len(STRINGS)} keys, {len(LANGUAGES)} languages)")

    KEYS.parent.mkdir(parents=True, exist_ok=True)
    with KEYS.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered_keys)
    print(f"wrote {KEYS.relative_to(REPO_ROOT)} ({len(STRINGS)} keys)")

    plural_path.parent.mkdir(parents=True, exist_ok=True)
    with plural_path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered_plurals)
    print(f"wrote {plural_path.relative_to(REPO_ROOT)}")

    strings_root = CATALOG.parent / "Compiled"
    for language, content in rendered_strings_files().items():
        directory = strings_root / f"{language}.lproj"
        directory.mkdir(parents=True, exist_ok=True)
        with (directory / "Localizable.strings").open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
    print(f"wrote {len(LANGUAGES)} .lproj bundles under {strings_root.relative_to(REPO_ROOT)}")
    missing = [
        (key, LANGUAGES[index])
        for key, values in STRINGS.items()
        for index, value in enumerate(values)
        if not value
    ]
    if missing:
        print(f"warning: {len(missing)} untranslated entries")
        for key, language in missing[:20]:
            print(f"  {key} [{language}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
