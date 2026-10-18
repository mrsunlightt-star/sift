#!/usr/bin/env python3
"""Generate Shared/Localization/Localizable.xcstrings from one reviewable table.

The string catalog is the single source of user-visible text (spec §11.5). Keeping
the table here means a reviewer can read every language side by side, and a
missing translation is caught by the build script below rather than discovered by
a user.

Usage:
    python3 Scripts/generate-strings.py            # writes the catalog
    python3 Scripts/generate-strings.py --check     # verifies it is current
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "Shared" / "Localization" / "Localizable.xcstrings"

# Source language. English is the fallback for every missing translation.
SOURCE = "en"

# Languages shipped in v1 (spec §11.5).
LANGUAGES = ["en", "zh-hans", "ko", "ru", "es", "ja", "fr", "de"]

# key: [en, zh-Hans, ko, ru, es, ja, fr, de]
STRINGS: dict[str, list[str]] = {
    # --- Application shell -------------------------------------------------
    "app.name": ["Sift", "Sift", "Sift", "Sift", "Sift", "Sift", "Sift", "Sift"],
    "app.tagline": [
        "Mac cleaner",
        "Mac 清理助手",
        "Mac 정리 도우미",
        "Очистка Mac",
        "Limpiador de Mac",
        "Mac クリーナー",
        "Nettoyeur Mac",
        "Mac-Reiniger",
    ],
    "nav.workbench": ["Workbench", "工作台", "워크벤치", "Рабочая область", "Área de trabajo", "ワークベンチ", "Espace de travail", "Arbeitsbereich"],
    "nav.dashboard": ["Overview", "总览", "개요", "Обзор", "Resumen", "概要", "Aperçu", "Übersicht"],
    "nav.smartScan": ["Smart Scan", "智能扫描", "스마트 스캔", "Умное сканирование", "Análisis inteligente", "スマートスキャン", "Analyse intelligente", "Intelligenter Scan"],
    "nav.junkCleanup": ["Junk Cleanup", "垃圾清理", "정리 정돈", "Очистка мусора", "Limpieza", "ジャンククリーニング", "Nettoyage", "Müll bereinigen"],
    "nav.uninstaller": ["Uninstaller", "软件卸载", "앱 제거", "Удаление программ", "Desinstalador", "アンインストーラ", "Désinstallation", "Deinstallation"],
    "nav.fileCleanup": ["File Cleanup", "文件清理", "파일 정리", "Очистка файлов", "Limpieza de archivos", "ファイルの整理", "Nettoyage de fichiers", "Dateien bereinigen"],
    "nav.storageAnalysis": ["Storage", "存储分析", "저장 공간 분석", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
    "nav.settings": ["Settings", "设置", "설정", "Настройки", "Ajustes", "設定", "Réglages", "Einstellungen"],
    "nav.help": ["Help and feedback", "帮助与反馈", "도움말 및 피드백", "Справка и отзывы", "Ayuda y comentarios", "ヘルプとフィードバック", "Aide et retours", "Hilfe und Feedback"],
    "nav.history": ["Scan history", "扫描历史", "스캔 기록", "История сканирований", "Historial de análisis", "スキャン履歴", "Historique des analyses", "Scan-Verlauf"],
    "nav.privacy": ["Privacy", "隐私说明", "개인정보", "Конфиденциальность", "Privacidad", "プライバシー", "Confidentialité", "Datenschutz"],

    # --- Dashboard ---------------------------------------------------------
    "dashboard.greeting.morning": ["Good morning", "早上好", "좋은 아침입니다", "Доброе утро", "Buenos días", "おはようございます", "Bonjour", "Guten Morgen"],
    "dashboard.greeting.afternoon": ["Good afternoon", "下午好", "안녕하세요", "Добрый день", "Buenas tardes", "こんにちは", "Bon après-midi", "Guten Tag"],
    "dashboard.greeting.evening": ["Good evening", "晚上好", "좋은 저녁입니다", "Добрый вечер", "Buenas noches", "こんばんは", "Bonsoir", "Guten Abend"],
    "dashboard.title": [
        "Ready to lighten your Mac?",
        "准备好让 Mac 轻一点了吗？",
        "Mac을 가볍게 만들 준비가 되셨나요?",
        "Готовы облегчить свой Mac?",
        "¿Listo para aligerar tu Mac?",
        "Mac を軽くしましょう",
        "Prêt à alléger votre Mac ?",
        "Bereit, Ihren Mac zu entlasten?",
    ],
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
    "dashboard.cleanable": ["Can be cleaned", "可清理空间", "정리 가능 공간", "Можно освободить", "Se puede limpiar", "削除可能", "Nettoyable", "Bereinigbar"],
    "dashboard.uninstallable": ["Apps to remove", "可卸载软件", "제거 가능한 앱", "Программ к удалению", "Apps para eliminar", "削除できるアプリ", "Apps à supprimer", "Apps zum Entfernen"],
    "dashboard.largeFiles": ["Large files", "大文件", "큰 파일", "Большие файлы", "Archivos grandes", "大きいファイル", "Fichiers volumineux", "Große Dateien"],
    "dashboard.largeFilesDetail": ["Files larger than %@", "超过 %@ 的文件", "%@ 이상인 파일", "Файлы больше %@", "Archivos mayores de %@", "%@ を超えるファイル", "Fichiers de plus de %@", "Dateien über %@"],
    "dashboard.lastScan": ["Last scan: %@", "上次扫描：%@", "마지막 검사: %@", "Последнее сканирование: %@", "Último análisis: %@", "前回のスキャン: %@", "Dernière analyse : %@", "Letzter Scan: %@"],
    "dashboard.neverScanned": ["Not scanned yet", "尚未扫描", "아직 검사하지 않음", "Ещё не сканировалось", "Aún no analizado", "未スキャン", "Pas encore analysé", "Noch nicht gescannt"],
    "dashboard.diskUsed": ["Disk used", "磁盘已使用", "디스크 사용량", "Диск занят", "Disco usado", "ディスク使用量", "Disque utilisé", "Belegt"],
    "dashboard.diskFree": ["%@ free", "%@ 可用", "%@ 사용 가능", "%@ свободно", "%@ libre", "空き %@", "%@ libres", "%@ frei"],
    "dashboard.suggestedCleanup": ["Suggested first", "建议优先处理", "우선 정리 권장", "Сначала обработать", "Sugerido primero", "先に処理する項目", "À traiter en priorité", "Zuerst bereinigen"],
    "dashboard.storageOverview": ["Storage overview", "存储概览", "저장 공간 개요", "Обзор хранилища", "Resumen de almacenamiento", "ストレージの概要", "Aperçu du stockage", "Speicherübersicht"],
    "dashboard.viewDetails": ["View details", "查看详情", "자세히 보기", "Подробнее", "Ver detalles", "詳細を表示", "Voir les détails", "Details anzeigen"],
    "dashboard.health": ["Mac health", "Mac 健康度", "Mac 상태", "Состояние Mac", "Estado del Mac", "Mac の状態", "État du Mac", "Mac-Zustand"],
    "dashboard.health.good": ["Good", "良好", "양호", "Хорошо", "Bueno", "良好", "Bon", "Gut"],
    "dashboard.health.review": ["Needs a look", "建议检查", "확인 필요", "Стоит проверить", "Conviene revisar", "確認をおすすめ", "À vérifier", "Prüfen empfohlen"],
    "dashboard.health.explain": ["Disk is %@ used", "磁盘已使用 %@", "디스크 %@ 사용 중", "Диск занят на %@", "Disco usado al %@", "ディスク使用率 %@", "Disque utilisé à %@", "Datenträger zu %@ belegt"],
    "dashboard.freedSoFar": ["Freed so far", "累计释放空间", "지금까지 확보한 공간", "Освобождено всего", "Liberado hasta ahora", "これまでに解放", "Espace libéré", "Bisher freigegeben"],
    "dashboard.cleanupSuggestion": [
        "Start with app caches and old installers: about %@ can be released.",
        "先处理应用缓存和旧安装包，预计可以释放 %@。",
        "앱 캐시와 오래된 설치 파일부터 처리하면 약 %@을 확보할 수 있습니다.",
        "Начните с кэшей приложений и старых установщиков: можно освободить около %@.",
        "Empieza por las cachés de apps y los instaladores antiguos: se pueden liberar unos %@.",
        "アプリのキャッシュと古いインストーラから始めると、約 %@ を解放できます。",
        "Commencez par les caches d’apps et les anciens installateurs : environ %@ peuvent être libérés.",
        "Beginnen Sie mit App-Caches und alten Installern: etwa %@ lassen sich freigeben.",
    ],
    "dashboard.lastCleanup": ["After the last cleanup", "上次清理后", "지난 정리 이후", "После последней очистки", "Tras la última limpieza", "前回のクリーンアップ後", "Après le dernier nettoyage", "Nach der letzten Bereinigung"],
    "dashboard.recentActivity": ["Recent activity", "最近活动", "최근 활동", "Недавние действия", "Actividad reciente", "最近のアクティビティ", "Activité récente", "Letzte Aktivitäten"],
    "dashboard.cleanupCompleted": ["Cleanup completed", "清理完成", "정리 완료", "Очистка завершена", "Limpieza completada", "クリーンアップ完了", "Nettoyage terminé", "Bereinigung abgeschlossen"],
    "dashboard.scanCompleted": ["Scan completed", "扫描完成", "검사 완료", "Сканирование завершено", "Análisis completado", "スキャン完了", "Analyse terminée", "Scan abgeschlossen"],
    "dashboard.spaceChange": ["Space change", "空间变化", "공간 변화", "Изменение места", "Cambio de espacio", "空き容量の変化", "Évolution de l’espace", "Speicheränderung"],
    "dashboard.before": ["Before", "清理前", "정리 전", "До", "Antes", "前", "Avant", "Vorher"],
    "dashboard.now": ["Now", "现在", "현재", "Сейчас", "Ahora", "現在", "Maintenant", "Jetzt"],
    "dashboard.lookSuggestions": ["Review suggestions", "查看建议", "제안 보기", "Посмотреть предложения", "Ver sugerencias", "提案を見る", "Voir les suggestions", "Vorschläge ansehen"],
    "dashboard.fasterMac": ["Make your Mac faster", "让 Mac 再快一点", "Mac을 더 빠르게", "Сделайте Mac быстрее", "Haz tu Mac más rápido", "Mac をもう少し軽く", "Accélérez votre Mac", "Mac schneller machen"],
    "dashboard.foundCleanable": ["Found %@ that can be safely cleaned.", "发现 %@ 可以安全清理的内容。", "안전하게 정리할 수 있는 %@을 찾았습니다.", "Найдено %@, что можно безопасно очистить.", "Se encontraron %@ que se pueden limpiar.", "安全に削除できる %@ が見つかりました。", "%@ peuvent être nettoyés sans risque.", "%@ können sicher bereinigt werden."],

    # --- Scan --------------------------------------------------------------
    "scan.title": ["Smart scan", "智能扫描", "스마트 스캔", "Умное сканирование", "Análisis inteligente", "スマートスキャン", "Analyse intelligente", "Intelligenter Scan"],
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
    "scan.checkedFiles": ["Checked %@ files", "已检查 %@ 个文件", "%@개 파일 확인함", "Проверено файлов: %@", "%@ archivos comprobados", "%@ 個のファイルを確認", "%@ fichiers vérifiés", "%@ Dateien geprüft"],
    "scan.itemsFound": ["%@ items found", "发现 %@ 个项目", "%@개 항목 발견", "Найдено элементов: %@", "%@ elementos encontrados", "%@ 項目が見つかりました", "%@ éléments trouvés", "%@ Einträge gefunden"],
    "scan.estimatedRelease": ["About %@ can be released", "预计可释放 %@", "약 %@ 확보 가능", "Можно освободить около %@", "Se pueden liberar unos %@", "約 %@ を解放できます", "Environ %@ peuvent être libérés", "Etwa %@ lassen sich freigeben"],
    "scan.results": ["Results", "扫描结果", "검사 결과", "Результаты", "Resultados", "結果", "Résultats", "Ergebnisse"],
    "scan.groupCount": ["%@ items", "%@ 个项目", "%@개 항목", "Элементов: %@", "%@ elementos", "%@ 項目", "%@ éléments", "%@ Einträge"],
    "scan.reviewDetails": ["View details", "查看明细", "세부 정보 보기", "Подробнее", "Ver detalles", "詳細を表示", "Voir le détail", "Details anzeigen"],
    "scan.selectAll": ["Select all", "全选", "전체 선택", "Выбрать всё", "Seleccionar todo", "すべて選択", "Tout sélectionner", "Alle auswählen"],
    "scan.deselectAll": ["Deselect all", "取消全选", "선택 해제", "Снять выбор", "Deselect all", "すべて解除", "Tout désélectionner", "Auswahl aufheben"],
    # The list is paged, so "select all" can only mean what the model holds. The
    # count is in the label rather than the ARIA text alone: the affordance is
    # what sets the expectation of how much will be selected.
    "scan.selectAllShown": ["Select all shown (%d)", "全选已显示（%d 项）", "표시된 항목 모두 선택(%d)", "Выбрать все показанные (%d)", "Seleccionar los mostrados (%d)", "表示中の %d 件をすべて選択", "Tout sélectionner parmi les %d affichés", "Alle %d angezeigten auswählen"],
    "scan.nothingFound": ["Nothing to clean up", "没有可清理项目", "정리할 항목이 없습니다", "Нечего очищать", "Nada que limpiar", "削除する項目はありません", "Rien à nettoyer", "Nichts zu bereinigen"],
    "scan.nothingFoundDetail": [
        "Your Mac looks tidy. Sift found no caches, logs or installers worth removing.",
        "你的 Mac 很整洁。Sift 没有发现值得清理的缓存、日志或安装包。",
        "Mac이 깨끗합니다. 정리할 만한 캐시, 로그 또는 설치 파일이 없습니다.",
        "Ваш Mac в порядке. Sift не нашёл кэшей, логов или установщиков, которые стоит удалить.",
        "Tu Mac está ordenado. Sift no encontró cachés, registros ni instaladores que merezca la pena eliminar.",
        "Mac はきれいな状態です。削除すべきキャッシュ、ログ、インストーラは見つかりませんでした。",
        "Votre Mac est propre. Sift n’a trouvé aucun cache, journal ou installateur à supprimer.",
        "Ihr Mac ist aufgeräumt. Sift fand keine Caches, Protokolle oder Installer, die sich lohnen.",
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
    "scan.duplicatesFound": ["%d duplicate groups", "%d 个重复文件组", "%d개 중복 그룹", "Групп дубликатов: %d", "%d grupos de duplicados", "%d 件の重複グループ", "%d groupes de doublons", "%d Duplikatgruppen"],

    # --- Cleanup -----------------------------------------------------------
    "cleanup.category.applicationCache": ["App caches", "应用缓存", "앱 캐시", "Кэши приложений", "Cachés de apps", "アプリのキャッシュ", "Caches d’apps", "App-Caches"],
    "cleanup.category.logs": ["Logs", "系统日志", "로그", "Логи", "Registros", "ログ", "Journaux", "Protokolle"],
    "cleanup.category.installers": ["Old installers", "旧安装包", "오래된 설치 파일", "Старые установщики", "Instaladores antiguos", "古いインストーラ", "Anciens installateurs", "Alte Installer"],
    "cleanup.category.temporaryFiles": ["Temporary files", "临时文件", "임시 파일", "Временные файлы", "Archivos temporales", "一時ファイル", "Fichiers temporaires", "Temporäre Dateien"],
    "cleanup.category.largeFiles": ["Large files", "大文件", "큰 파일", "Большие файлы", "Archivos grandes", "大きいファイル", "Fichiers volumineux", "Große Dateien"],
    "cleanup.category.oldFiles": ["Old files", "旧文件", "오래된 파일", "Старые файлы", "Archivos antiguos", "古いファイル", "Fichiers anciens", "Alte Dateien"],
    "cleanup.category.duplicateFiles": ["Duplicate files", "重复文件", "중복 파일", "Дубликаты файлов", "Archivos duplicados", "重複ファイル", "Doublons", "Duplikate"],
    "cleanup.category.applicationResidue": ["App leftovers", "应用残留", "앱 잔여 파일", "Остатки приложений", "Restos de apps", "アプリの残留物", "Résidus d’apps", "App-Reste"],

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
    "cleanup.explanation.systemLogs": [
        "System log files older than %d days. Some require Full Disk Access to read.",
        "%d 天前的系统日志。部分需要完全磁盘访问权限。",
        "%d일이 지난 시스템 로그입니다. 일부는 전체 디스크 접근 권한이 필요합니다.",
        "Системные журналы старше %d дней. Для некоторых нужен полный доступ к диску.",
        "Registros del sistema de más de %d días. Algunos requieren acceso total al disco.",
        "%d 日より前のシステムログです。一部はフルディスクアクセスが必要です。",
        "Journaux système de plus de %d jours. Certains exigent un accès complet au disque.",
        "Systemprotokolle älter als %d Tage. Einige erfordern vollständigen Festplattenzugriff.",
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
    "cleanup.confirm.byCategory": ["By category", "按类型分组", "유형별", "По категориям", "Por categoría", "種類別", "Par catégorie", "Nach Kategorie"],
    "cleanup.confirm.release": ["Space to be released", "预计释放空间", "확보될 공간", "Будет освобождено", "Espacio a liberar", "解放される容量", "Espace libéré", "Freizugebender Speicher"],
    "cleanup.confirm.method": ["Method", "处理方式", "처리 방법", "Способ", "Método", "処理方法", "Méthode", "Methode"],
    "cleanup.confirm.methodValue": ["Move to Trash (recoverable)", "移入废纸篓（可恢复）", "휴지통으로 이동 (복구 가능)", "Переместить в Корзину (можно вернуть)", "Mover a la papelera (recuperable)", "ゴミ箱へ移動（復元可能）", "Déplacer vers la corbeille (récupérable)", "In den Papierkorb (wiederherstellbar)"],
    "cleanup.confirm.keepOpen": ["Keep window open", "保持窗口打开", "창 열어 두기", "Оставить окно открытым", "Mantener ventana abierta", "ウィンドウを開いたまま", "Garder la fenêtre ouverte", "Fenster offen lassen"],
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
    "cleanup.result.failed": ["%d items could not be removed", "%d 个项目无法删除", "%d개 항목을 삭제할 수 없습니다", "Не удалось удалить: %d", "%d elementos no se pudieron eliminar", "%d 個を削除できませんでした", "%d éléments n’ont pas pu être supprimés", "%d Einträge konnten nicht entfernt werden"],
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

    "cleanup.failure.permissionDenied": ["Permission denied", "权限不足", "권한 없음", "Нет доступа", "Permiso denegado", "権限がありません", "Autorisation refusée", "Keine Berechtigung"],
    "cleanup.failure.fileNotFound": ["Already removed", "已被移除", "이미 제거됨", "Уже удалено", "Ya eliminado", "すでに削除済み", "Déjà supprimé", "Bereits entfernt"],
    "cleanup.failure.fileInUse": ["File is in use", "文件正在使用", "파일 사용 중", "Файл используется", "Archivo en uso", "ファイルが使用中", "Fichier en cours d’utilisation", "Datei wird verwendet"],
    # The path no longer resolves to what the user selected: the item was moved,
    # or an ancestor was replaced by a symlink, between the pre-flight check and
    # the move. Refused rather than followed.
    "cleanup.failure.itemChanged": ["Moved or replaced", "已移动或被替换", "이동 또는 교체됨", "Перемещено или заменено", "Movido o reemplazado", "移動または置換済み", "Déplacé ou remplacé", "Verschoben oder ersetzt"],
    "cleanup.failure.volumeUnavailable": ["Disk disconnected", "磁盘已断开", "디스크 연결 끊김", "Диск отключён", "Disco desconectado", "ディスクが接続されていません", "Disque déconnecté", "Datenträger getrennt"],
    "cleanup.failure.protectedLocation": ["Protected location", "受保护的位置", "보호된 위치", "Защищённое место", "Ubicación protegida", "保護された場所", "Emplacement protégé", "Geschützter Ort"],
    "cleanup.failure.partialFailure": ["Partly completed", "部分完成", "일부 완료", "Выполнено частично", "Completado parcialmente", "一部完了", "Partiellement terminé", "Teilweise abgeschlossen"],
    "cleanup.failure.retry": ["Retry", "重试", "다시 시도", "Повторить", "Reintentar", "再試行", "Réessayer", "Erneut versuchen"],

    # --- Uninstaller -------------------------------------------------------
    "uninstall.title": ["Uninstall apps", "卸载软件", "앱 제거", "Удаление программ", "Desinstalar apps", "アプリを削除", "Désinstaller des apps", "Apps deinstallieren"],
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
    "uninstall.relatedFiles": ["Related files", "关联文件", "관련 파일", "Связанные файлы", "Archivos relacionados", "関連ファイル", "Fichiers associés", "Zugehörige Dateien"],
    "uninstall.confirmedRelated": ["Confirmed for this app", "明确关联", "확실한 관련 파일", "Точно относятся к приложению", "Confirmados para esta app", "このアプリに確実に関連", "Confirmés pour cette app", "Sicher zugehörig"],
    "uninstall.needsReview": ["Needs your confirmation", "需要手动确认", "확인 필요", "Требуют подтверждения", "Necesitan tu confirmación", "確認が必要", "À confirmer", "Prüfung erforderlich"],
    "uninstall.bundleId": ["Bundle ID: %@", "Bundle ID：%@", "번들 ID: %@", "Bundle ID: %@", "Bundle ID: %@", "バンドル ID: %@", "Bundle ID : %@", "Bundle-ID: %@"],
    "uninstall.version": ["Version %@", "版本 %@", "버전 %@", "Версия %@", "Versión %@", "バージョン %@", "Version %@", "Version %@"],
    "uninstall.appSize": ["App: %@", "应用：%@", "앱: %@", "Приложение: %@", "App: %@", "アプリ: %@", "App : %@", "App: %@"],
    "uninstall.relatedSize": ["Related files: %@", "关联文件：%@", "관련 파일: %@", "Связанные файлы: %@", "Archivos relacionados: %@", "関連ファイル: %@", "Fichiers associés : %@", "Zugehörige Dateien: %@"],
    "uninstall.totalSize": ["Total: %@", "共计：%@", "합계: %@", "Итого: %@", "Total: %@", "合計: %@", "Total : %@", "Gesamt: %@"],
    "uninstall.uninstallButton": ["Uninstall %@", "卸载 %@", "제거 %@", "Удалить %@", "Desinstalar %@", "%@ をアンインストール", "Désinstaller %@", "%@ deinstallieren"],
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
    "uninstall.noRelatedFiles": ["No related files were found.", "没有找到关联文件。", "관련 파일을 찾지 못했습니다.", "Связанные файлы не найдены.", "No se encontraron archivos relacionados.", "関連ファイルは見つかりませんでした。", "Aucun fichier associé trouvé.", "Keine zugehörigen Dateien gefunden."],
    "uninstall.selectApp": ["Choose an app to see what would be removed.", "选择一个应用以查看将被删除的内容。", "앱을 선택하면 제거될 항목을 볼 수 있습니다.", "Выберите приложение, чтобы увидеть, что будет удалено.", "Elige una app para ver qué se eliminaría.", "アプリを選択すると削除内容を確認できます。", "Choisissez une app pour voir ce qui serait supprimé.", "Wählen Sie eine App, um zu sehen, was entfernt würde."],

    # --- File cleanup ------------------------------------------------------
    "files.title": ["File cleanup", "文件清理", "파일 정리", "Очистка файлов", "Limpieza de archivos", "ファイルの整理", "Nettoyage de fichiers", "Dateien bereinigen"],
    "files.mode.large": ["Large files", "大文件", "큰 파일", "Большие файлы", "Archivos grandes", "大きいファイル", "Fichiers volumineux", "Große Dateien"],
    "files.mode.old": ["Old files", "旧文件", "오래된 파일", "Старые файлы", "Archivos antiguos", "古いファイル", "Fichiers anciens", "Alte Dateien"],
    "files.mode.duplicates": ["Duplicates", "重复文件", "중복 파일", "Дубликаты", "Duplicados", "重複ファイル", "Doublons", "Duplikate"],
    "files.threshold.large": ["Larger than %@", "大于 %@", "%@ 이상", "Больше %@", "Mayores de %@", "%@ を超える", "Plus de %@", "Größer als %@"],
    "files.threshold.old": ["Not changed for %d days", "%d 天未修改", "%d일 미변경", "Без изменений %d дней", "Sin cambios durante %d días", "%d 日間変更なし", "Non modifiés depuis %d jours", "Seit %d Tagen unverändert"],
    "files.scanDuplicates": ["Find duplicates", "查找重复文件", "중복 파일 찾기", "Найти дубликаты", "Buscar duplicados", "重複を検索", "Trouver les doublons", "Duplikate finden"],
    "files.chooseFolders": ["Choose folders to check", "选择要检查的文件夹", "검사할 폴더 선택", "Выбрать папки для проверки", "Elegir carpetas a revisar", "確認するフォルダを選択", "Choisir les dossiers à vérifier", "Ordner zum Prüfen wählen"],
    "files.duplicateGroups": ["%d duplicate groups, %@ reclaimable", "%d 个重复组，可释放 %@", "중복 그룹 %d개, %@ 확보 가능", "Групп дубликатов: %d, можно освободить %@", "%d grupos de duplicados, %@ recuperables", "重複グループ %d 件、%@ を解放可能", "%d groupes de doublons, %@ récupérables", "%d Duplikatgruppen, %@ freigebbar"],
    # Shown when the group list is paged: the user has to be able to tell how
    # much of the result they are looking at.
    "files.duplicateGroupsShown": ["Showing %d of %d groups", "已显示 %d / %d 组", "%d / %d 그룹 표시", "Показано %d из %d групп", "Mostrando %d de %d grupos", "%d / %d グループを表示", "%d groupes sur %d affichés", "%d von %d Gruppen angezeigt"],
    "files.groupMembers": ["%d copies", "%d 份副本", "%d개 사본", "Копий: %d", "%d copias", "%d 個のコピー", "%d copies", "%d Kopien"],
    "files.keepThis": ["Keep this one", "保留此项", "이 항목 유지", "Оставить этот", "Conservar este", "これを残す", "Conserver celui-ci", "Diese behalten"],
    "files.removeThese": ["%d copies will be removed", "%d 份副本将被删除", "%d개 사본이 삭제됩니다", "Будет удалено копий: %d", "Se eliminarán %d copias", "%d 個のコピーを削除します", "%d copies seront supprimées", "%d Kopien werden entfernt"],
    "files.noDuplicates": ["No duplicate files found", "没有找到重复文件", "중복 파일이 없습니다", "Дубликаты не найдены", "No se encontraron duplicados", "重複ファイルは見つかりませんでした", "Aucun doublon trouvé", "Keine Duplikate gefunden"],
    "files.revealInFinder": ["Show in Finder", "在访达中显示", "Finder에서 보기", "Показать в Finder", "Mostrar en el Finder", "Finder で表示", "Afficher dans le Finder", "Im Finder zeigen"],
    "files.ignore": ["Ignore this item", "加入忽略列表", "이 항목 무시", "Игнорировать", "Ignorar este elemento", "この項目を無視", "Ignorer cet élément", "Diesen Eintrag ignorieren"],
    "files.ignored": ["Ignored items are never scanned again.", "忽略的项目不会再被扫描。", "무시한 항목은 다시 검사하지 않습니다.", "Игнорируемые элементы больше не сканируются.", "Los elementos ignorados no se analizan de nuevo.", "無視した項目は再スキャンされません。", "Les éléments ignorés ne sont plus analysés.", "Ignorierte Einträge werden nicht mehr gescannt."],
    "files.emptyFolder": ["No files matched in this folder.", "此文件夹中没有符合条件的文件。", "이 폴더에서 조건에 맞는 파일이 없습니다.", "В этой папке ничего не найдено.", "No hay archivos que coincidan en esta carpeta.", "このフォルダに該当ファイルはありません。", "Aucun fichier correspondant dans ce dossier.", "In diesem Ordner wurden keine Dateien gefunden."],
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
    "diagnostics.title": ["System space diagnostics", "系统空间诊断", "시스템 공간 진단", "Диагностика места в системе", "Diagnóstico de espacio del sistema", "システム容量の診断", "Diagnostic de l’espace système", "Systemspeicher-Diagnose"],
    "diagnostics.intro": ["What actually occupies the disk, what it is, and whether it can be rebuilt. This page never removes anything.", "磁盘空间究竟被什么占用、这些数据是什么、能否重建。此页面不会删除任何内容。", "디스크를 실제로 차지하는 것, 그것이 무엇인지, 다시 만들 수 있는지 보여 줍니다. 이 페이지는 아무것도 삭제하지 않습니다.", "Что на самом деле занимает диск, что это и можно ли это перестроить. Эта страница ничего не удаляет.", "Qué ocupa realmente el disco, qué es y si se puede reconstruir. Esta página no elimina nada.", "ディスクを実際に占めているもの、それが何か、再構築できるかを示します。このページは何も削除しません。", "Ce qui occupe réellement le disque, ce que c’est et si cela peut être reconstruit. Cette page ne supprime rien.", "Was die Festplatte tatsächlich belegt, was es ist und ob es sich neu aufbauen lässt. Diese Seite entfernt nichts."],
    "diagnostics.analyze": ["Analyse", "开始诊断", "진단 시작", "Анализировать", "Analizar", "診断する", "Analyser", "Analysieren"],
    "diagnostics.analyzing": ["Analysing…", "诊断中…", "진단 중…", "Анализ…", "Analizando…", "診断中…", "Analyse…", "Analyse läuft…"],
    "diagnostics.scope.includeVolume": ["Also analyse the volume root", "同时分析卷根目录", "볼륨 최상위도 분석", "Анализировать и корень тома", "Analizar también la raíz del volumen", "ボリューム直下も分析する", "Analyser aussi la racine du volume", "Auch die Volume-Wurzel analysieren"],
    "diagnostics.scope.note": ["Your home folder and the locations you added in settings are always included.", "始终包含你的个人文件夹和你在设置中添加的位置。", "홈 폴더와 설정에서 추가한 위치는 항상 포함됩니다.", "Ваша домашняя папка и добавленные в настройках места включены всегда.", "Tu carpeta personal y las ubicaciones que añadiste en Ajustes se incluyen siempre.", "ホームフォルダと設定で追加した場所は常に含まれます。", "Votre dossier personnel et les emplacements ajoutés dans les Réglages sont toujours inclus.", "Ihr Benutzerordner und die in den Einstellungen hinzugefügten Orte sind immer enthalten."],
    "diagnostics.coverage.note": ["Open System Settings to grant Full Disk Access, then run the analysis again.", "在系统设置中授予完全磁盘访问权限，然后重新运行诊断。", "시스템 설정에서 전체 디스크 접근 권한을 허용한 뒤 다시 진단하세요.", "Выдайте полный доступ к диску в Системных настройках и запустите анализ снова.", "Concede acceso total al disco en Ajustes del Sistema y vuelve a analizar.", "システム設定でフルディスクアクセスを許可し、もう一度診断してください。", "Accordez l’accès complet au disque dans les Réglages Système, puis relancez l’analyse.", "Erteilen Sie in den Systemeinstellungen Vollzugriff auf die Festplatte und starten Sie die Analyse erneut."],
    "diagnostics.section.categories": ["Largest by category", "按类别占用", "카테고리별 사용량", "Крупнейшее по категориям", "Mayores por categoría", "カテゴリ別の上位", "Les plus volumineux par catégorie", "Größte nach Kategorie"],
    "diagnostics.section.protected": ["Protected, but large", "受保护但占用较大", "보호되지만 큰 항목", "Защищено, но много места", "Protegido pero voluminoso", "保護されているが大きい項目", "Protégé mais volumineux", "Geschützt, aber groß"],
    "diagnostics.section.rebuildable": ["Can be rebuilt", "可以重建", "다시 만들 수 있음", "Можно перестроить", "Se puede reconstruir", "再構築できるもの", "Peut être reconstruit", "Kann neu aufgebaut werden"],
    "diagnostics.section.cleanable": ["Suitable for the cleanup flow", "可进入清理流程", "정리 흐름으로 넘길 수 있음", "Подходит для очистки", "Apto para la limpieza", "整理の対象にできるもの", "Éligible au nettoyage", "Für die Bereinigung geeignet"],
    "diagnostics.section.snapshots": ["Snapshots", "快照", "스냅샷", "Снимки", "Instantáneas", "スナップショット", "Instantanés", "Snapshots"],
    "diagnostics.section.skipped": ["Could not be read", "无法读取的位置", "읽을 수 없는 위치", "Не удалось прочитать", "No se pudo leer", "読み取れなかった場所", "Non lisible", "Nicht lesbar"],
    "diagnostics.empty": ["Nothing large was found in this scope.", "在此范围内没有发现占用较大的内容。", "이 범위에서 큰 항목을 찾지 못했습니다.", "В этой области ничего крупного не найдено.", "No se encontró nada voluminoso en este alcance.", "この範囲には大きな項目はありませんでした。", "Rien de volumineux dans cette portée.", "In diesem Bereich wurde nichts Großes gefunden."],
    "diagnostics.note.approximate": ["Sizes are estimates: clones and snapshots make allocated space non-additive.", "大小是估算值：克隆和快照会使分配空间不能简单相加。", "크기는 추정값입니다. 클론과 스냅샷 때문에 할당 공간은 단순 합산이 되지 않습니다.", "Размеры приблизительны: из-за клонов и снимков выделенное место не складывается напрямую.", "Los tamaños son estimaciones: los clones y las instantáneas hacen que el espacio asignado no sea aditivo.", "サイズは推定値です。クローンやスナップショットがあるため、割り当て容量は単純に合計できません。", "Les tailles sont estimées : les clones et les instantanés rendent l’espace alloué non additif.", "Größen sind Schätzwerte: Klone und Snapshots machen belegten Speicher nicht addierbar."],
    "diagnostics.note.readOnly": ["Diagnostics only reads. Nothing here is removed, and a cleanup still goes through the normal confirmation.", "诊断只做读取。这里的任何内容都不会被删除；如要清理，仍会走正常的确认流程。", "진단은 읽기만 합니다. 여기서 아무것도 삭제되지 않으며, 정리는 평소의 확인 절차를 거칩니다.", "Диагностика только читает. Здесь ничего не удаляется, а очистка по-прежнему проходит обычное подтверждение.", "El diagnóstico solo lee. Aquí no se elimina nada y cualquier limpieza pasa por la confirmación habitual.", "診断は読み取りのみです。ここでは何も削除されず、整理する場合も通常の確認を行います。", "Le diagnostic ne fait que lire. Rien n’est supprimé ici, et un nettoyage passe toujours par la confirmation habituelle.", "Die Diagnose liest nur. Hier wird nichts entfernt, und eine Bereinigung durchläuft weiterhin die übliche Bestätigung."],

    "files.manageScope": ["Manage in Settings", "在设置中管理", "설정에서 관리", "Управлять в настройках", "Gestionar en Ajustes", "設定で管理", "Gérer dans les Réglages", "In den Einstellungen verwalten"],
    "files.scopeEmpty": ["No folders yet. Duplicates are searched only in folders you add.", "还没有文件夹。重复文件只在你添加的文件夹中搜索。", "아직 폴더가 없습니다. 중복 파일은 추가한 폴더에서만 검색합니다.", "Папок пока нет. Дубликаты ищутся только в добавленных папках.", "Aún no hay carpetas. Los duplicados se buscan solo en las carpetas que añadas.", "まだフォルダがありません。重複ファイルは追加したフォルダ内だけを検索します。", "Aucun dossier pour l’instant. Les doublons ne sont cherchés que dans les dossiers ajoutés.", "Noch keine Ordner. Duplikate werden nur in hinzugefügten Ordnern gesucht."],
    "settings.group.authorized": ["Authorised folders", "已授权文件夹", "승인된 폴더", "Разрешённые папки", "Carpetas autorizadas", "許可されたフォルダ", "Dossiers autorisés", "Autorisierte Ordner"],
    "settings.authorized.empty": ["Nothing has been authorised yet. Folders you add here are scanned, and used to find duplicates.", "尚未授权任何位置。在此添加的文件夹会被扫描，并用于查找重复文件。", "아직 승인된 위치가 없습니다. 여기에서 추가한 폴더는 검사되며 중복 파일 찾기에 사용됩니다.", "Пока ничего не разрешено. Добавленные здесь папки сканируются и используются для поиска дубликатов.", "Aún no has autorizado nada. Las carpetas que añadas aquí se analizan y se usan para buscar duplicados.", "まだ何も許可されていません。ここで追加したフォルダはスキャンされ、重複ファイルの検索に使われます。", "Rien n’est encore autorisé. Les dossiers ajoutés ici sont analysés et servent à trouver les doublons.", "Noch nichts autorisiert. Hier hinzugefügte Ordner werden gescannt und für die Duplikatsuche verwendet."],
    "settings.staleThreshold": ["Stale threshold", "过期阈值", "오래된 항목 기준", "Порог устаревания", "Umbral de antigüedad", "古い項目のしきい値", "Seuil d’ancienneté", "Schwelle für veraltete Einträge"],
    "storage.includeVolume": ["Include the whole volume", "包含整卷分析", "볼륨 전체 포함", "Включить весь том", "Incluir todo el volumen", "ボリューム全体を含める", "Inclure tout le volume", "Gesamtes Volume einbeziehen"],
    "storage.scopeNote": ["Home and the folders you authorised. Including the volume scans the whole disk and takes longer.", "个人文件夹和你授权的文件夹。包含整卷会扫描整个磁盘，耗时更长。", "홈과 승인한 폴더입니다. 볼륨 전체를 포함하면 디스크 전체를 검사하므로 더 오래 걸립니다.", "Домашняя папка и разрешённые папки. Весь том означает сканирование всего диска и занимает больше времени.", "Tu carpeta personal y las carpetas autorizadas. Incluir el volumen analiza todo el disco y tarda más.", "ホームと許可したフォルダです。ボリューム全体を含めるとディスク全体を走査するため時間がかかります。", "Votre dossier personnel et les dossiers autorisés. Inclure le volume analyse tout le disque et prend plus de temps.", "Ihr Benutzerordner und die autorisierten Ordner. Das gesamte Volume zu einbeziehen scannt die ganze Festplatte und dauert länger."],
    "settings.authorized.unavailable": ["Not available in this session", "本次会话不可用", "이번 세션에서 사용할 수 없음", "Недоступно в этом сеансе", "No disponible en esta sesión", "このセッションでは利用できません", "Indisponible pour cette session", "In dieser Sitzung nicht verfügbar"],
    "files.scopeTitle": ["Folders you added", "你添加的文件夹", "추가한 폴더", "Добавленные папки", "Carpetas que añadiste", "追加したフォルダ", "Dossiers que vous avez ajoutés", "Von Ihnen hinzugefügte Ordner"],
    "settings.removeLicense": ["Remove stored licence key", "移除已存的许可证密钥", "저장된 라이선스 키 제거", "Удалить сохранённый лицензионный ключ", "Eliminar la clave de licencia guardada", "保存済みのライセンスキーを削除", "Supprimer la clé de licence enregistrée", "Gespeicherten Lizenzschlüssel entfernen"],
    # --- Storage -----------------------------------------------------------
    "storage.title": ["Storage", "存储分析", "저장 공간", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
    "storage.volume": ["Volume", "卷", "볼륨", "Том", "Volumen", "ボリューム", "Volume", "Volume"],
    "storage.used": ["%@ used of %@", "已使用 %@ / %@", "%@ / %@ 사용", "Занято %@ из %@", "%@ usados de %@", "%@ / %@ 使用中", "%@ utilisés sur %@", "%@ von %@ belegt"],
    "storage.byType": ["By file type", "按类型", "파일 유형별", "По типу файлов", "Por tipo de archivo", "ファイルの種類別", "Par type de fichier", "Nach Dateityp"],
    "storage.categories": ["Categories", "分类占用", "카테고리", "Категории", "Categorías", "カテゴリ", "Catégories", "Kategorien"],
    "storage.topFiles": ["Largest files", "最大文件", "큰 파일 순위", "Самые большие файлы", "Archivos más grandes", "大きいファイル順", "Fichiers les plus volumineux", "Größte Dateien"],
    "storage.topDirectories": ["Largest folders", "最大目录", "큰 폴더 순위", "Самые большие папки", "Carpetas más grandes", "大きいフォルダ順", "Dossiers les plus volumineux", "Größte Ordner"],
    "storage.directoryTree": ["Folders", "可展开目录树", "폴더 트리", "Папки", "Carpetas", "フォルダ", "Dossiers", "Ordner"],
    "storage.analyze": ["Analyze storage", "分析存储", "저장 공간 분석", "Анализировать хранилище", "Analizar almacenamiento", "ストレージを分析", "Analyser le stockage", "Speicher analysieren"],
    "storage.analysing": ["Analyzing…", "分析中…", "분석 중…", "Анализ…", "Analizando…", "分析中…", "Analyse…", "Analyse läuft…"],
    "storage.externalDisk": ["External disk", "外部磁盘", "외장 디스크", "Внешний диск", "Disco externo", "外付けディスク", "Disque externe", "Externes Laufwerk"],
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
    "storage.notAuthorized": [
        "Add this folder in settings to include it in storage analysis.",
        "在设置中添加此文件夹即可纳入存储分析。",
        "설정에서 이 폴더를 추가하면 분석에 포함됩니다.",
        "Добавьте эту папку в настройках, чтобы включить её в анализ.",
        "Añade esta carpeta en ajustes para incluirla en el análisis.",
        "設定でこのフォルダを追加すると分析に含まれます。",
        "Ajoutez ce dossier dans les réglages pour l’inclure à l’analyse.",
        "Fügen Sie diesen Ordner in den Einstellungen hinzu, um ihn einzubeziehen.",
    ],
    "storage.reclaimable": ["Reclaimable", "可回收空间", "확보 가능", "Можно освободить", "Recuperable", "解放可能", "Récupérable", "Freigebbar"],

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
    "settings.requireConfirmation": ["Ask for confirmation before cleaning", "清理前要求确认", "정리 전 확인", "Спрашивать перед очисткой", "Pedir confirmación antes de limpiar", "削除前に確認する", "Demander confirmation avant nettoyage", "Vor dem Bereinigen bestätigen"],
    "settings.skipConfirmation": ["Skip confirmation", "跳过确认", "확인 건너뛰기", "Пропускать подтверждение", "Omitir confirmación", "確認をスキップ", "Ignorer la confirmation", "Bestätigung überspringen"],
    "settings.skipConfirmationWarning": [
        "Sift will start cleaning as soon as you click. Items still go to the Trash, but you will not see the list first.",
        "点击后 Sift 会立即开始清理。内容仍会进入废纸篓，但不会先显示列表。",
        "클릭하면 바로 정리를 시작합니다. 항목은 휴지통으로 이동하지만 목록을 먼저 볼 수 없습니다.",
        "Sift начнёт очистку сразу после нажатия. Файлы попадут в Корзину, но список вы не увидите.",
        "Sift empezará a limpiar al hacer clic. Todo irá a la papelera, pero no verás la lista antes.",
        "クリックするとすぐに削除が始まります。ゴミ箱には入りますが、一覧は表示されません。",
        "Sift nettoiera dès le clic. Les éléments iront à la corbeille, mais sans liste préalable.",
        "Sift beginnt sofort nach dem Klick. Alles landet im Papierkorb, aber ohne vorherige Liste.",
    ],
    "settings.appearance.system": ["Follow system", "跟随系统", "시스템 설정 따르기", "Как в системе", "Según el sistema", "システムに従う", "Suivre le système", "Systemeinstellung"],
    "settings.appearance.light": ["Light", "浅色", "라이트", "Светлое", "Claro", "ライト", "Clair", "Hell"],
    "settings.appearance.dark": ["Dark", "深色", "다크", "Тёмное", "Oscuro", "ダーク", "Sombre", "Dunkel"],
    "settings.reduceMotion": ["Reduce motion", "减少动态效果", "동작 줄이기", "Уменьшить движение", "Reducir movimiento", "視差効果を減らす", "Réduire les animations", "Bewegung reduzieren"],
    "settings.languageRestart": [
        "Some texts change after you reopen the window.",
        "部分文案会在重新打开窗口后更新。",
        "일부 문구는 창을 다시 열면 반영됩니다.",
        "Часть текста обновится после повторного открытия окна.",
        "Algunos textos cambian al reabrir la ventana.",
        "一部の文言はウィンドウを開き直すと反映されます。",
        "Certains textes changent après réouverture de la fenêtre.",
        "Einige Texte ändern sich nach dem erneuten Öffnen des Fensters.",
    ],
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
    "settings.scanHistory": ["Scan history", "扫描历史", "검사 기록", "История сканирований", "Historial de análisis", "スキャン履歴", "Historique des analyses", "Scan-Verlauf"],
    "settings.scanHistoryDetail": ["The last %d scans are kept on this Mac.", "本机保留最近 %d 次扫描记录。", "최근 %d회 검사 기록이 이 Mac에 저장됩니다.", "На этом Mac хранятся последние %d сканирований.", "Se guardan los últimos %d análisis en este Mac.", "この Mac に直近 %d 回のスキャンを保存します。", "Les %d derniers analyses sont conservés sur ce Mac.", "Die letzten %d Scans bleiben auf diesem Mac."],
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
    "purchase.freeTierTitle": ["What you can do for free", "免费版可以做什么", "무료로 할 수 있는 것", "Что доступно бесплатно", "Lo que puedes hacer gratis", "無料でできること", "Ce que vous pouvez faire gratuitement", "Was kostenlos möglich ist"],
    "purchase.freeTier.scan": ["Scan your whole Mac", "扫描整台 Mac", "Mac 전체 검사", "Сканировать весь Mac", "Analizar todo tu Mac", "Mac 全体をスキャン", "Analyser tout votre Mac", "Den ganzen Mac scannen"],
    "purchase.freeTier.explain": ["See every item, its source and its risk", "查看每个项目的来源和风险", "모든 항목의 출처와 위험도 확인", "Видеть каждый элемент, источник и риск", "Ver cada elemento, su origen y su riesgo", "各項目の由来とリスクを確認", "Voir chaque élément, son origine et son risque", "Jeden Eintrag mit Quelle und Risiko sehen"],
    "purchase.freeTier.estimate": ["See how much space you could release", "查看可释放空间估算", "확보 가능한 공간 확인", "Оценить освобождаемое место", "Ver cuánto espacio podrías liberar", "解放できる容量の推定を見る", "Voir l’espace récupérable", "Sehen, wie viel frei wird"],
    "purchase.freeTier.storage": ["Analyze storage by type and folder", "按类型和目录分析存储", "유형 및 폴더별 분석", "Анализ хранилища по типам и папкам", "Analizar por tipo y carpeta", "種類とフォルダ別に分析", "Analyser par type et dossier", "Nach Typ und Ordner analysieren"],
    "purchase.paidTierTitle": ["What unlocking adds", "解锁后新增", "잠금 해제 시 추가", "Что даёт разблокировка", "Lo que añade el desbloqueo", "アンロックで追加される機能", "Ce que le déblocage ajoute", "Was die Freischaltung bringt"],
    "purchase.paidTier.clean": ["Move caches, logs and installers to Trash", "将缓存、日志和安装包移入废纸篓", "캐시, 로그, 설치 파일을 휴지통으로 이동", "Переместить кэши, логи и установщики в Корзину", "Mover cachés, registros e instaladores a la papelera", "キャッシュ、ログ、インストーラをゴミ箱へ", "Déplacer caches, journaux et installateurs à la corbeille", "Caches, Protokolle und Installer in den Papierkorb"],
    "purchase.paidTier.uninstall": ["Uninstall apps with their related files", "连同关联文件卸载应用", "관련 파일과 함께 앱 제거", "Удалять приложения вместе со связанными файлами", "Desinstalar apps con sus archivos", "関連ファイルごとアプリを削除", "Désinstaller les apps avec leurs fichiers", "Apps samt zugehörigen Dateien entfernen"],
    "purchase.paidTier.files": ["Clean large, old and duplicate files", "清理大文件、旧文件和重复文件", "큰 파일, 오래된 파일, 중복 파일 정리", "Чистить большие, старые и дублирующие файлы", "Limpiar archivos grandes, antiguos y duplicados", "大きい・古い・重複ファイルを整理", "Nettoyer les fichiers volumineux, anciens et doublons", "Große, alte und doppelte Dateien bereinigen"],
    "purchase.paidTier.report": ["Full cleanup reports and PDF export", "完整清理报告和 PDF 导出", "전체 정리 보고서 및 PDF 내보내기", "Полные отчёты и экспорт в PDF", "Informes completos y exportación a PDF", "完全なレポートと PDF 書き出し", "Rapports complets et export PDF", "Vollständige Berichte und PDF-Export"],
    "purchase.buyButton": ["Buy for %@", "购买（%@）", "%@에 구매", "Купить за %@", "Comprar por %@", "%@ で購入", "Acheter pour %@", "Für %@ kaufen"],
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
    "common.continue": ["Continue", "继续", "계속", "Продолжить", "Continuar", "続ける", "Continuer", "Weiter"],
    "common.remove": ["Remove", "移除", "제거", "Удалить", "Eliminar", "削除", "Supprimer", "Entfernen"],
    "common.keep": ["Keep", "保留", "유지", "Оставить", "Conservar", "残す", "Conserver", "Behalten"],
    "common.unknownError": ["Something went wrong. Please try again.", "出现错误，请重试。", "문제가 발생했습니다. 다시 시도해 주세요.", "Что-то пошло не так. Повторите попытку.", "Algo salió mal. Inténtalo de nuevo.", "問題が発生しました。もう一度お試しください。", "Une erreur est survenue. Réessayez.", "Etwas ist schiefgelaufen. Bitte erneut versuchen."],
    "common.fileCount": ["%d files", "%d 个文件", "%d개 파일", "Файлов: %d", "%d archivos", "%d 個のファイル", "%d fichiers", "%d Dateien"],
    "common.itemCount": ["%d items", "%d 个项目", "%d개 항목", "Элементов: %d", "%d elementos", "%d 項目", "%d éléments", "%d Einträge"],
    "common.today": ["Today", "今天", "오늘", "Сегодня", "Hoy", "今日", "Aujourd’hui", "Heute"],
    "common.yesterday": ["Yesterday", "昨天", "어제", "Вчера", "Ayer", "昨日", "Hier", "Gestern"],
    "common.daysAgo": ["%d days ago", "%d 天前", "%d일 전", "%d дней назад", "Hace %d días", "%d 日前", "Il y a %d jours", "Vor %d Tagen"],
    "common.notAvailable": ["Not available", "不可用", "사용할 수 없음", "Недоступно", "No disponible", "利用できません", "Indisponible", "Nicht verfügbar"],
    "common.loadMore": ["Load more", "加载更多", "더 불러오기", "Показать ещё", "Cargar más", "さらに読み込む", "Afficher plus", "Mehr laden"],
    "common.learnMore": ["Learn more", "了解更多", "자세히 알아보기", "Подробнее", "Más información", "詳細を見る", "En savoir plus", "Mehr erfahren"],
    "common.retry": ["Try again", "重试", "다시 시도", "Повторить", "Reintentar", "再試行", "Réessayer", "Erneut versuchen"],
    "common.selected": ["%d selected", "已选 %d 项", "%d개 선택", "Выбрано: %d", "%d seleccionados", "%d 件選択", "%d sélectionnés", "%d ausgewählt"],
    "common.of": ["%@ of %@", "%@ / %@", "%@ / %@", "%@ из %@", "%@ de %@", "%@ / %@", "%@ sur %@", "%@ von %@"],
    "common.path": ["Path", "路径", "경로", "Путь", "Ruta", "パス", "Chemin", "Pfad"],
    "common.size": ["Size", "大小", "크기", "Размер", "Tamaño", "サイズ", "Taille", "Größe"],
    "common.modified": ["Modified", "修改时间", "수정일", "Изменён", "Modificado", "変更日", "Modifié", "Geändert"],
    "common.risk": ["Risk", "风险等级", "위험도", "Риск", "Riesgo", "リスク", "Risque", "Risiko"],
    "common.reason": ["Why", "原因", "이유", "Причина", "Motivo", "理由", "Raison", "Grund"],
    "common.apply": ["Apply", "应用", "적용", "Применить", "Aplicar", "適用", "Appliquer", "Anwenden"],
    "common.refresh": ["Refresh", "刷新", "새로 고침", "Обновить", "Actualizar", "再読み込み", "Actualiser", "Aktualisieren"],
    "common.quitApp": ["Quit app", "退出应用", "앱 종료", "Закрыть приложение", "Cerrar app", "アプリを終了", "Quitter l’app", "App beenden"],
    "common.emptyFolder": ["This folder is empty", "此文件夹为空", "이 폴더는 비어 있습니다", "Эта папка пуста", "Esta carpeta está vacía", "このフォルダは空です", "Ce dossier est vide", "Dieser Ordner ist leer"],
    "common.loading": ["Loading…", "加载中…", "불러오는 중…", "Загрузка…", "Cargando…", "読み込み中…", "Chargement…", "Wird geladen…"],
    "common.sortBy": ["Sort by", "排序方式", "정렬 기준", "Сортировать по", "Ordenar por", "並べ替え", "Trier par", "Sortieren nach"],
    "common.filter": ["Filter", "筛选", "필터", "Фильтр", "Filtrar", "絞り込み", "Filtrer", "Filtern"],
}


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


def main() -> int:
    catalog = build_catalog()
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n"

    if "--check" in sys.argv:
        current = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
        if current != rendered:
            print("Localizable.xcstrings is out of date; run Scripts/generate-strings.py")
            return 1
        print(f"Localizable.xcstrings is current ({len(STRINGS)} keys, {len(LANGUAGES)} languages)")
        return 0

    CATALOG.parent.mkdir(parents=True, exist_ok=True)
    with CATALOG.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    print(f"wrote {CATALOG.relative_to(REPO_ROOT)} ({len(STRINGS)} keys, {len(LANGUAGES)} languages)")

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
