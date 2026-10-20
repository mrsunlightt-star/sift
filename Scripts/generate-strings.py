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
    "nav.group.cleanup": ["Cleanup", "清理", "정리", "Очистка", "Limpieza", "クリーニング", "Nettoyage", "Bereinigung"],
    "nav.group.apps": ["Apps & Storage", "应用与存储", "앱 및 저장 공간", "Приложения и хранилище", "Apps y almacenamiento", "アプリとストレージ", "Apps et stockage", "Apps & Speicher"],
    "nav.dashboard": ["Overview", "总览", "개요", "Обзор", "Resumen", "概要", "Aperçu", "Übersicht"],
    "nav.smartScan": ["Smart Scan", "智能扫描", "스마트 스캔", "Умное сканирование", "Análisis inteligente", "スマートスキャン", "Analyse intelligente", "Intelligenter Scan"],
    "nav.junkCleanup": ["Junk Cleanup", "垃圾清理", "정리 정돈", "Очистка мусора", "Limpieza", "ジャンククリーニング", "Nettoyage", "Müll bereinigen"],
    "nav.uninstaller": ["Uninstaller", "软件卸载", "앱 제거", "Удаление программ", "Desinstalador", "アンインストーラ", "Désinstallation", "Deinstallation"],
    "nav.fileCleanup": ["File Cleanup", "文件清理", "파일 정리", "Очистка файлов", "Limpieza de archivos", "ファイルの整理", "Nettoyage de fichiers", "Dateien bereinigen"],
    "nav.storageAnalysis": ["Storage", "存储", "저장 공간 분석", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
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
    "storage.includeVolume": ["Include whole-volume diagnostics", "包含整卷诊断", "볼륨 전체 진단 포함", "Включить диагностику всего тома", "Incluir diagnóstico de todo el volumen", "ボリューム全体の診断を含める", "Inclure le diagnostic du volume entier", "Diagnose des gesamten Volumes einbeziehen"],
    "storage.scopeNote": ["File categories cover your home folder and authorised folders on this disk. The toggle adds whole-volume system diagnostics.", "文件分类统计个人文件夹和此磁盘上已授权的文件夹；开关会为系统诊断加入整卷范围。", "파일 분류는 홈과 이 디스크에서 승인한 폴더를 포함합니다. 스위치는 시스템 진단에 볼륨 전체를 포함합니다.", "Категории файлов охватывают домашнюю папку и разрешённые папки на этом диске. Переключатель добавляет диагностику всего тома.", "Las categorías cubren tu carpeta personal y las carpetas autorizadas en este disco. La opción añade el diagnóstico de todo el volumen.", "ファイル分類はホームとこのディスク上で許可したフォルダを対象にします。スイッチはシステム診断にボリューム全体を加えます。", "Les catégories couvrent votre dossier personnel et les dossiers autorisés sur ce disque. L’option ajoute le diagnostic du volume entier.", "Die Dateikategorien umfassen Ihren Benutzerordner und autorisierte Ordner auf diesem Volume. Die Option ergänzt die Systemdiagnose für das gesamte Volume."],
    "settings.authorized.unavailable": ["Not available in this session", "本次会话不可用", "이번 세션에서 사용할 수 없음", "Недоступно в этом сеансе", "No disponible en esta sesión", "このセッションでは利用できません", "Indisponible pour cette session", "In dieser Sitzung nicht verfügbar"],
    "files.scopeTitle": ["Folders you added", "你添加的文件夹", "추가한 폴더", "Добавленные папки", "Carpetas que añadiste", "追加したフォルダ", "Dossiers que vous avez ajoutés", "Von Ihnen hinzugefügte Ordner"],
    "settings.removeLicense": ["Remove stored licence key", "移除已存的许可证密钥", "저장된 라이선스 키 제거", "Удалить сохранённый лицензионный ключ", "Eliminar la clave de licencia guardada", "保存済みのライセンスキーを削除", "Supprimer la clé de licence enregistrée", "Gespeicherten Lizenzschlüssel entfernen"],
    # --- Storage -----------------------------------------------------------
    "storage.title": ["Storage", "存储", "저장 공간", "Хранилище", "Almacenamiento", "ストレージ", "Stockage", "Speicher"],
    "storage.volume": ["Volume", "卷", "볼륨", "Том", "Volumen", "ボリューム", "Volume", "Volume"],
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
    "storage.categories": ["Categories", "分类占用", "카테고리", "Категории", "Categorías", "カテゴリ", "Catégories", "Kategorien"],
    "storage.topFiles": ["Largest files", "最大文件", "큰 파일 순위", "Самые большие файлы", "Archivos más grandes", "大きいファイル順", "Fichiers les plus volumineux", "Größte Dateien"],
    "storage.topDirectories": ["Largest folders", "最大目录", "큰 폴더 순위", "Самые большие папки", "Carpetas más grandes", "大きいフォルダ順", "Dossiers les plus volumineux", "Größte Ordner"],
    "storage.directoryTree": ["Folders", "可展开目录树", "폴더 트리", "Папки", "Carpetas", "フォルダ", "Dossiers", "Ordner"],
    "storage.analyze": ["Analyze storage", "分析存储", "저장 공간 분석", "Анализировать хранилище", "Analizar almacenamiento", "ストレージを分析", "Analyser le stockage", "Speicher analysieren"],
    "storage.start": ["Start analysis", "开始分析", "분석 시작", "Начать анализ", "Iniciar análisis", "分析を開始", "Lancer l’analyse", "Analyse starten"],
    "storage.reanalyze": ["Analyze again", "重新分析", "다시 분석", "Повторить анализ", "Analizar de nuevo", "再分析", "Réanalyser", "Erneut analysieren"],
    "storage.cancelAnalysis": ["Cancel analysis", "取消分析", "분석 취소", "Отменить анализ", "Cancelar análisis", "分析を中止", "Annuler l’analyse", "Analyse abbrechen"],
    "storage.lastAnalyzed": ["Last analysed %@", "上次分析：%@", "마지막 분석: %@", "Последний анализ: %@", "Último análisis: %@", "前回の分析: %@", "Dernière analyse : %@", "Zuletzt analysiert: %@"],
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
    "settings.userRules": ["Use a custom rule file", "使用自定义规则文件", "사용자 규칙 파일 사용", "Использовать файл правил", "Usar un archivo de reglas", "カスタムルールファイルを使用", "Utiliser un fichier de règles", "Eigene Regeldatei verwenden"],
    "settings.userRulesDetail": ["Reads CleaningRules.json from the app's data folder. Applies to the next scan.", "从应用数据目录读取 CleaningRules.json，下一次扫描生效。", "앱 데이터 폴더의 CleaningRules.json을 읽습니다. 다음 검사부터 적용됩니다.", "Читает CleaningRules.json из папки данных приложения. Применяется со следующего сканирования.", "Lee CleaningRules.json de la carpeta de datos de la app. Se aplica al próximo análisis.", "アプリのデータフォルダの CleaningRules.json を読み込みます。次回のスキャンから適用されます。", "Lit CleaningRules.json dans le dossier de données de l’app. S’applique au prochain scan.", "Liest CleaningRules.json aus dem Datenordner der App. Gilt ab dem nächsten Scan."],
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
    # --- Redesigned navigation, overview, scan, apps and storage -----------
    "nav.scan": ["Scan", "扫描", "스캔", "Сканирование", "Analizar", "スキャン", "Analyse", "Scan"],
    "nav.apps": ["Apps", "应用", "앱", "Приложения", "Apps", "アプリ", "Apps", "Apps"],

    "overview.scanScope": ["What a scan covers", "可扫描的内容", "검사 대상", "Что охватывает сканирование", "Qué cubre el análisis", "スキャンの対象", "Ce que couvre l’analyse", "Was ein Scan abdeckt"],
    "overview.status": ["Workbench · %@", "工作台 · %@", "워크벤치 · %@", "Рабочая область · %@", "Área de trabajo · %@", "ワークベンチ · %@", "Espace de travail · %@", "Arbeitsbereich · %@"],
    "overview.reclaimable.title": ["Safe to release", "本次可安全释放", "안전하게 확보 가능", "Можно безопасно освободить", "Se puede liberar", "安全に解放できる容量", "Libérable sans risque", "Sicher freigebbar"],
    "overview.reclaimable.breakdown": ["%@ is safe, %@ needs your confirmation", "其中 %@ 为安全项，%@ 需要你确认后清理", "이 중 %@은 안전하고, %@은 확인 후 정리할 수 있습니다", "Из них %@ безопасно, %@ требует подтверждения", "De ellos, %@ es seguro y %@ requiere confirmación", "うち %@ は安全、%@ は確認後に削除できます", "Dont %@ sans risque, %@ à confirmer", "%@ sind sicher, %@ brauchen Ihre Bestätigung"],
    "overview.reclaimable.meta": ["%d categories · %d items", "%d 类 · %d 项", "%d개 카테고리 · %d개 항목", "Категорий: %d · элементов: %d", "%d categorías · %d elementos", "%d カテゴリ · %d 項目", "%d catégories · %d éléments", "%d Kategorien · %d Einträge"],
    "overview.ready": ["Ready to scan", "准备就绪", "검사 준비 완료", "Готово к сканированию", "Listo para analizar", "スキャンの準備完了", "Prêt à analyser", "Bereit zum Scannen"],
    "overview.noResults": ["Run a scan to see what can be safely released.", "扫描后，这里会显示可以安全释放的空间。", "검사를 실행하면 안전하게 확보할 수 있는 공간이 표시됩니다.", "Запустите сканирование, чтобы увидеть, сколько можно безопасно освободить.", "Ejecuta un análisis para ver cuánto se puede liberar.", "スキャンすると、安全に解放できる容量が表示されます。", "Lancez une analyse pour voir ce qui peut être libéré.", "Starten Sie einen Scan, um zu sehen, was sicher freigegeben werden kann."],
    "overview.viewProgress": ["View scan progress", "查看扫描进度", "검사 진행 상황 보기", "Открыть ход сканирования", "Ver progreso del análisis", "スキャンの進行状況を見る", "Voir la progression", "Scan-Fortschritt ansehen"],
    "overview.noCleanup": ["No cleanup yet", "还没有清理记录", "아직 정리 기록 없음", "Очисток ещё не было", "Aún no hay limpiezas", "クリーンアップ履歴なし", "Aucun nettoyage", "Noch keine Bereinigung"],
    "overview.cleanupHistoryHint": ["Cleanup history appears here.", "清理记录会显示在这里。", "정리 기록이 여기에 표시됩니다.", "Здесь появится история очисток.", "El historial de limpiezas aparecerá aquí.", "クリーンアップ履歴がここに表示されます。", "L’historique des nettoyages apparaîtra ici.", "Der Bereinigungsverlauf erscheint hier."],
    "overview.viewResults": ["View scan results", "查看扫描结果", "검사 결과 보기", "Открыть результаты", "Ver resultados", "スキャン結果を見る", "Voir les résultats", "Scan-Ergebnisse"],
    "overview.localOnly": ["The scan runs entirely on this Mac.", "扫描全程在本机完成", "검사는 전부 이 Mac에서 실행됩니다.", "Сканирование выполняется только на этом Mac.", "El análisis se ejecuta por completo en este Mac.", "スキャンはすべてこの Mac 上で行われます。", "L’analyse s’exécute entièrement sur ce Mac.", "Der Scan läuft vollständig auf diesem Mac."],
    "overview.diskRemaining": ["Free space", "可用空间", "사용 가능 공간", "Свободно", "Espacio libre", "空き容量", "Espace libre", "Freier Speicher"],
    "overview.diskUsageDetail": ["%@ free · %@ total", "剩余 %@ · 共 %@", "%@ 사용 가능 · 총 %@", "%@ свободно · всего %@", "%@ libres · %@ en total", "空き %@ · 合計 %@", "%@ libres · %@ au total", "%@ frei · %@ gesamt"],
    "overview.lastCleanupTitle": ["Last cleanup released", "上次清理释放", "지난 정리로 확보", "Освобождено в прошлый раз", "Liberado en la última limpieza", "前回のクリーンアップで解放", "Libéré au dernier nettoyage", "Zuletzt freigegeben"],
    "overview.lastCleanupMeta": ["%@ · %d items · moved to Trash", "%@ · %d 项 · 全部移至废纸篓", "%@ · %d개 항목 · 휴지통으로 이동", "%@ · элементов: %d · в Корзину", "%@ · %d elementos · a la papelera", "%@ · %d 項目 · ゴミ箱へ移動", "%@ · %d éléments · à la corbeille", "%@ · %d Einträge · in den Papierkorb"],
    "overview.selectSafe": ["Select all safe items", "全选安全项", "안전 항목 모두 선택", "Выбрать все безопасные", "Seleccionar todo lo seguro", "安全な項目をすべて選択", "Tout sélectionner sans risque", "Alle sicheren auswählen"],
    "overview.selectedSummary": ["%d selected · %@", "已选 %d 项 · %@", "%d개 선택 · %@", "Выбрано: %d · %@", "%d seleccionados · %@", "%d 件選択 · %@", "%d sélectionnés · %@", "%d ausgewählt · %@"],
    "overview.moreItems": ["%d smaller items · %@ in total", "还有 %d 项较小内容 · 合计 %@", "작은 항목 %d개 · 합계 %@", "Мелких элементов: %d · всего %@", "%d elementos menores · %@ en total", "小さい項目 %d 件 · 合計 %@", "%d éléments plus petits · %@ au total", "%d kleinere Einträge · %@ gesamt"],
    "overview.showAll": ["Show all", "展开全部", "모두 펼치기", "Показать все", "Mostrar todo", "すべて表示", "Tout afficher", "Alle anzeigen"],
    "overview.historyLocal": ["History stays on this Mac; nothing is synced or uploaded.", "记录仅保存在本机，不同步、不上传。", "기록은 이 Mac에만 저장되며 동기화되거나 업로드되지 않습니다.", "История хранится только на этом Mac и никуда не отправляется.", "El historial permanece en este Mac; no se sincroniza ni se sube.", "履歴はこの Mac にのみ保存され、同期や送信はされません。", "L’historique reste sur ce Mac ; rien n’est synchronisé ni envoyé.", "Der Verlauf bleibt auf diesem Mac; nichts wird synchronisiert oder hochgeladen."],
    "overview.activityScan": ["Scan completed · %d items", "智能扫描完成 · 发现 %d 项", "검사 완료 · %d개 발견", "Сканирование завершено · найдено %d", "Análisis completado · %d elementos", "スキャン完了 · %d 項目", "Analyse terminée · %d éléments", "Scan abgeschlossen · %d Einträge"],
    "overview.activityUninstall": ["Uninstall advice · %d apps not opened recently", "卸载建议 · %d 个应用长期未打开", "제거 제안 · 최근 미실행 앱 %d개", "Совет по удалению · приложений без запуска: %d", "Sugerencia de desinstalación · %d apps sin abrir", "アンインストール提案 · 長期間未使用 %d アプリ", "Conseil de désinstallation · %d apps inutilisées", "Deinstallationshinweis · %d Apps lange nicht geöffnet"],
    "overview.activityStorage": ["Storage analysed · %@ measured", "存储分析完成 · 已分析 %@", "저장 공간 분석 완료 · %@ 분석", "Хранилище проанализировано · измерено %@", "Almacenamiento analizado · %@ medidos", "ストレージ分析完了 · %@ を計測", "Stockage analysé · %@ mesurés", "Speicher analysiert · %@ gemessen"],

    "scan.filter.all": ["All", "全部", "전체", "Все", "Todo", "すべて", "Tout", "Alle"],
    "scan.filter.junk": ["Junk", "垃圾", "정리 대상", "Мусор", "Basura", "ジャンク", "Déchets", "Müll"],
    "scan.filter.large": ["Large", "大文件", "큰 파일", "Большие", "Grandes", "大きいファイル", "Volumineux", "Große"],
    "scan.filter.old": ["Old", "旧文件", "오래된 파일", "Старые", "Antiguos", "古いファイル", "Anciens", "Alte"],
    "scan.filter.duplicates": ["Duplicates", "重复", "중복", "Дубликаты", "Duplicados", "重複", "Doublons", "Duplikate"],
    "scan.rescan": ["Scan again", "重新扫描", "다시 검사", "Сканировать снова", "Analizar de nuevo", "再スキャン", "Relancer l’analyse", "Erneut scannen"],
    "scan.headerStatus": ["Scan · results from %@ · %d items", "扫描 · 结果来自 %@ · 共 %d 项", "스캔 · %@ 결과 · %d개 항목", "Сканирование · результат от %@ · элементов: %d", "Análisis · resultados de %@ · %d elementos", "スキャン · %@ の結果 · %d 項目", "Analyse · résultats du %@ · %d éléments", "Scan · Ergebnisse vom %@ · %d Einträge"],
    "scan.headerStatusEmpty": ["Scan · nothing scanned yet", "扫描 · 尚未扫描", "스캔 · 아직 검사하지 않음", "Сканирование · ещё не выполнялось", "Análisis · aún sin analizar", "スキャン · 未実行", "Analyse · pas encore lancée", "Scan · noch nicht gescannt"],
    "scan.results.safeGroup": ["Safe to clean", "可安全清理", "안전하게 정리 가능", "Можно безопасно очистить", "Se puede limpiar", "安全に削除可能", "Nettoyable sans risque", "Sicher bereinigbar"],
    "scan.results.reviewGroup": ["Needs your confirmation", "需要你确认", "확인 필요", "Требует подтверждения", "Requiere confirmación", "確認が必要", "À confirmer", "Bestätigung nötig"],
    "scan.results.protectedGroup": ["Protected", "受保护", "보호됨", "Защищено", "Protegido", "保護済み", "Protégé", "Geschützt"],
    "scan.results.defaultSelected": ["Selected by default", "默认已选中", "기본 선택됨", "Выбрано по умолчанию", "Seleccionado por defecto", "既定で選択", "Sélectionné par défaut", "Standardmäßig ausgewählt"],
    "scan.results.reviewHint": ["Confirm each item before cleaning", "逐项确认后才可清理", "항목별로 확인 후 정리할 수 있습니다", "Подтвердите каждый элемент", "Confirma cada elemento antes de limpiar", "項目ごとに確認してから削除します", "Confirmez chaque élément", "Jeden Eintrag bestätigen"],
    "scan.results.cleanTitle": ["This cleanup", "本次清理", "이번 정리", "Эта очистка", "Esta limpieza", "今回のクリーンアップ", "Ce nettoyage", "Diese Bereinigung"],
    "scan.results.cleanButton": ["Clean %d items", "清理 %d 项", "%d개 정리", "Очистить: %d", "Limpiar %d", "%d 件を削除", "Nettoyer %d", "%d bereinigen"],
    "scan.results.trashHint": ["Moved to the Trash by default; recoverable until you empty it.", "默认移入废纸篓，清空废纸篓前可恢复。", "기본적으로 휴지통으로 이동하며, 비우기 전까지 복구할 수 있습니다.", "По умолчанию в Корзину; можно восстановить до её очистки.", "Se mueve a la papelera; puedes recuperarlo hasta vaciarla.", "既定でゴミ箱に移動し、ゴミ箱を空にするまで復元できます。", "Déplacé dans la corbeille ; récupérable jusqu’à ce que vous la vidiez.", "Standardmäßig in den Papierkorb; bis zum Leeren wiederherstellbar."],
    "scan.results.protectedHint": ["System files and protected locations are skipped automatically", "自动跳过系统文件与受保护路径", "시스템 파일과 보호된 경로는 자동으로 건너뜁니다", "Системные файлы и защищённые места пропускаются автоматически", "Los archivos del sistema y las ubicaciones protegidas se omiten", "システムファイルと保護された場所は自動で除外されます", "Les fichiers système et emplacements protégés sont ignorés", "Systemdateien und geschützte Orte werden automatisch übersprungen"],
    "scan.results.reportHint": ["Restore from the Trash, or export a cleanup report.", "可在废纸篓恢复，或导出清理报告。", "휴지통에서 복구하거나 정리 보고서를 내보낼 수 있습니다.", "Восстановите из Корзины или экспортируйте отчёт.", "Restaura desde la papelera o exporta un informe.", "ゴミ箱から復元するか、レポートを書き出せます。", "Restaurez depuis la corbeille ou exportez un rapport.", "Aus dem Papierkorb wiederherstellen oder einen Bericht exportieren."],
    "scan.results.sortSize": ["By size", "按大小", "크기순", "По размеру", "Por tamaño", "サイズ順", "Par taille", "Nach Größe"],
    "scan.results.sortName": ["By name", "按名称", "이름순", "По имени", "Por nombre", "名前順", "Par nom", "Nach Name"],
    "scan.results.sortModified": ["By modification date", "按修改时间", "수정일순", "По дате изменения", "Por fecha de modificación", "更新日順", "Par date de modification", "Nach Änderungsdatum"],
    "scan.results.categoryTotals": ["By category: %@", "按类别：%@", "카테고리별: %@", "По категориям: %@", "Por categoría: %@", "カテゴリ別: %@", "Par catégorie : %@", "Nach Kategorie: %@"],
    "scan.running.status": ["Scanning · step %d of %d", "扫描进行中 · 第 %d 步，共 %d 步", "검사 중 · %d단계 / 총 %d단계", "Сканирование · шаг %d из %d", "Analizando · paso %d de %d", "スキャン中 · %d / %d ステップ", "Analyse · étape %d sur %d", "Scan · Schritt %d von %d"],
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

    "apps.status": ["Installed %d · %d not opened in 6 months", "已安装 %d 个 · %d 个超过 6 个月未打开", "설치 %d개 · 6개월 이상 미실행 %d개", "Установлено: %d · не открывались 6 месяцев: %d", "%d instaladas · %d sin abrir en 6 meses", "インストール %d 件 · 6 か月以上未使用 %d 件", "%d installées · %d non ouvertes depuis 6 mois", "%d installiert · %d seit 6 Monaten nicht geöffnet"],
    "apps.listTitle": ["Applications", "应用列表", "앱 목록", "Приложения", "Aplicaciones", "アプリ一覧", "Applications", "Apps"],
    "apps.sortSummary": ["Sorted by size · %@ in total", "按体积排序 · 共 %@", "크기순 · 총 %@", "По размеру · всего %@", "Por tamaño · %@ en total", "サイズ順 · 合計 %@", "Par taille · %@ au total", "Nach Größe · %@ gesamt"],
    "apps.reclaimable": ["Can be released", "本次可释放", "확보 가능", "Можно освободить", "Se puede liberar", "解放できる容量", "Libérable", "Freigebbar"],
    "apps.appAndRelated": ["App %@ · related files %@", "应用本体 %@ · 关联文件 %@", "앱 %@ · 관련 파일 %@", "Приложение %@ · связанные файлы %@", "App %@ · archivos relacionados %@", "アプリ %@ · 関連ファイル %@", "App %@ · fichiers associés %@", "App %@ · zugehörige Dateien %@"],
    "apps.relatedWillRemove": ["Related files to remove", "将一并删除的关联文件", "함께 삭제할 관련 파일", "Связанные файлы к удалению", "Archivos relacionados que se eliminarán", "一緒に削除する関連ファイル", "Fichiers associés à supprimer", "Zugehörige Dateien zum Entfernen"],
    "apps.uninstallAndClean": ["Uninstall and clean %@", "卸载并清理 %@", "제거하고 %@ 정리", "Удалить и очистить %@", "Desinstalar y limpiar %@", "アンインストールして %@ を整理", "Désinstaller et nettoyer %@", "Deinstallieren und %@ bereinigen"],
    "apps.restoreHint": ["Recoverable from the Trash until you empty it", "清空废纸篓前可恢复", "휴지통을 비우기 전까지 복구 가능", "Можно восстановить из Корзины до её очистки", "Recuperable de la papelera hasta vaciarla", "ゴミ箱を空にするまで復元できます", "Récupérable depuis la corbeille", "Bis zum Leeren des Papierkorbs wiederherstellbar"],
    "apps.footer": ["Showing apps over 200 MB · %d total", "仅显示超过 200 MB 的应用 · 共 %d 个", "200MB 초과 앱만 표시 · 총 %d개", "Показаны приложения больше 200 МБ · всего %d", "Apps de más de 200 MB · %d en total", "200 MB 超のアプリのみ表示 · 全 %d 件", "Apps de plus de 200 Mo · %d au total", "Apps über 200 MB · %d gesamt"],
    "apps.lastOpened": ["Last opened %@", "上次打开于%@", "마지막 실행 %@", "Последний запуск: %@", "Última apertura: %@", "最終使用：%@", "Dernière ouverture : %@", "Zuletzt geöffnet: %@"],
    "apps.neverOpened": ["Never opened", "从未打开", "실행 기록 없음", "Не открывалось", "Nunca abierta", "未使用", "Jamais ouverte", "Nie geöffnet"],

    "storage.startTitle": ["See what occupies the disk", "看看磁盘被什么占用", "디스크를 무엇이 차지하는지 확인", "Посмотрите, что занимает диск", "Mira qué ocupa el disco", "ディスクを何が占めているか見る", "Voyez ce qui occupe le disque", "Sehen Sie, was den Speicher belegt"],
    "storage.headerStatus": ["Storage · %@", "存储 · %@", "저장 공간 · %@", "Хранилище · %@", "Almacenamiento · %@", "ストレージ · %@", "Stockage · %@", "Speicher · %@"],
    "storage.status": ["%@ · %@ used of %@", "%@ · 已用 %@，共 %@", "%@ · %@ 사용 / 총 %@", "%@ · занято %@ из %@", "%@ · %@ usado de %@", "%@ · %@ / %@ 使用", "%@ · %@ utilisé sur %@", "%@ · %@ von %@ belegt"],
    "storage.spaceDistribution": ["Space distribution", "空间分布", "공간 분포", "Распределение пространства", "Distribución del espacio", "スペースの内訳", "Répartition de l’espace", "Speicherverteilung"],
    "storage.categoryDetail": ["Category breakdown", "分类明细", "카테고리 내역", "По категориям", "Desglose por categoría", "カテゴリ別内訳", "Détail par catégorie", "Kategorieübersicht"],
    "storage.usageShare": ["Usage", "占用占比", "사용 비율", "Использовано", "Uso", "使用率", "Utilisation", "Belegung"],
    "storage.availableSpace": ["Available", "可用空间", "사용 가능", "Свободно", "Disponible", "空き容量", "Disponible", "Verfügbar"],
    "storage.otherUsed": ["Other used", "其他已用", "기타 사용", "Прочее занято", "Otro usado", "その他の使用", "Autre utilisé", "Sonstiges belegt"],
    "storage.localNote": ["Measured on this Mac. Nothing is uploaded or sent online.", "数据来自本机分析，不上传、不联网。", "이 Mac에서 분석한 데이터입니다. 업로드하거나 전송하지 않습니다.", "Измерено на этом Mac. Ничего не отправляется в сеть.", "Medido en este Mac. No se sube ni se envía nada.", "この Mac で計測したデータです。送信やアップロードは行いません。", "Mesuré sur ce Mac. Rien n’est envoyé en ligne.", "Auf diesem Mac gemessen. Nichts wird hochgeladen oder gesendet."],
    "storage.suggestionTitle": ["Suggestion", "建议", "제안", "Рекомендация", "Sugerencia", "提案", "Suggestion", "Empfehlung"],
    "storage.cleanableHeading": ["%@ can be cleaned", "%@ 可清理", "%@ 정리 가능", "Можно очистить %@", "Se pueden limpiar %@", "%@ を削除できます", "%@ peuvent être nettoyés", "%@ können bereinigt werden"],
    "storage.suggestionDetail": ["Start with caches and old installers, then scan again to confirm.", "先处理缓存和旧安装包，再扫描一次确认。", "캐시와 오래된 설치 파일부터 처리한 뒤 다시 검사하세요.", "Начните с кэшей и старых установщиков, затем просканируйте снова.", "Empieza por las cachés y los instaladores antiguos; luego analiza de nuevo.", "キャッシュと古いインストーラから処理し、もう一度スキャンしてください。", "Commencez par les caches et les anciens installateurs, puis relancez l’analyse.", "Beginnen Sie mit Caches und alten Installern und scannen Sie dann erneut."],
    "storage.goClean": ["Go clean", "去清理", "정리하러 가기", "Перейти к очистке", "Ir a limpiar", "整理する", "Nettoyer", "Bereinigen"],
    "storage.analyzedSummary": ["%@ measured · %@ files", "已分析 %@ · %@ 个文件", "%@ 분석 · %@개 파일", "Измерено %@ · файлов: %@", "%@ medidos · %@ archivos", "%@ を計測 · %@ ファイル", "%@ mesurés · %@ fichiers", "%@ gemessen · %@ Dateien"],

    "settings.headerStatus": ["Settings · Sift %@", "设置 · Sift %@", "설정 · Sift %@", "Настройки · Sift %@", "Ajustes · Sift %@", "設定 · Sift %@", "Réglages · Sift %@", "Einstellungen · Sift %@"],
    "common.sort": ["Sort", "排序", "정렬", "Сортировка", "Ordenar", "並び替え", "Trier", "Sortieren"],
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
    catalog = build_catalog()
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    rendered_keys = swift_keys_source()

    if "--check" in sys.argv:
        current = CATALOG.read_text(encoding="utf-8") if CATALOG.exists() else ""
        if current != rendered:
            print("Localizable.xcstrings is out of date; run Scripts/generate-strings.py")
            return 1
        keys_current = KEYS.read_text(encoding="utf-8") if KEYS.exists() else ""
        if keys_current != rendered_keys:
            print("LocalizationKey.swift is out of date; run Scripts/generate-strings.py")
            return 1
        print(
            f"Localizable.xcstrings and LocalizationKey.swift are current "
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
