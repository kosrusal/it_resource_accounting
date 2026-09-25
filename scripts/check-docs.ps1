#Requires -Version 7.0
# Проверка структуры документов; выполнение будущих функций ПО не проверяется.
$ErrorActionPreference = 'Stop'
$taskRepoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()
$requirements = [System.Collections.Generic.List[object]]::new()
$linkCount = 0
$markdownFiles = Get-ChildItem -LiteralPath $taskRepoRoot -Filter '*.md' -File -Recurse

foreach ($file in $markdownFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    foreach ($match in [regex]::Matches($content, '\[[^\]\r\n]*\]\(([^\s)]+)\)')) {
        $target = $match.Groups[1].Value.Trim('<', '>')
        if ($target -match '^(https?://|mailto:|#)') { continue }
        $relativePath = [uri]::UnescapeDataString(($target -split '#', 2)[0])
        if (-not $relativePath) { continue }
        $resolvedPath = Join-Path $file.DirectoryName $relativePath
        $linkCount++
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            $failures.Add("Недействительная ссылка: $($file.Name) -> $target")
        }
    }

    # В главе внешних задач отдельная таблица источников повторно перечисляет номера.
    $requirementPart = ($content -split '(?m)^## Прослеживаемость', 2)[0]
    foreach ($line in ($requirementPart -split '\r?\n')) {
        if ($line -notmatch '^\|\s*((?:СТ|ТП)-[А-ЯЁ]+-\d{2})\s*\|') { continue }
        $id = $Matches[1]
        $cells = $line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }
        $isSoftware = $id.StartsWith('ТП-')
        $expectedCount = if ($file.Name -eq 'tracker-system.md') { 3 } else { 4 }
        if ($cells.Count -ne $expectedCount -or @($cells | Where-Object { -not $_ }).Count) {
            $failures.Add("Неполная строка требования: $id")
        }
        $expectedStart = if ($isSoftware) { 'Программное обеспечение должно ' } else { 'Система должна ' }
        if (-not $cells[1].StartsWith($expectedStart)) {
            $failures.Add("Неверная форма требования: $id")
        }
        $parents = @()
        if ($isSoftware) {
            $parents = @([regex]::Matches($cells[2], 'СТ-[А-ЯЁ]+-\d{2}') | ForEach-Object { $_.Value })
            if ($parents.Count -eq 0) { $failures.Add("Нет системного основания: $id") }
        }
        $requirements.Add([pscustomobject]@{ Id = $id; Software = $isSoftware; Parents = $parents })
    }
}

foreach ($group in ($requirements | Group-Object Id)) {
    if ($group.Count -gt 1) { $failures.Add("Повтор номера: $($group.Name)") }
}
$systemIds = @($requirements | Where-Object { -not $_.Software } | ForEach-Object { $_.Id })
$softwareRows = @($requirements | Where-Object { $_.Software })
$covered = @{}
foreach ($row in $softwareRows) {
    foreach ($parent in $row.Parents) {
        if ($parent -notin $systemIds) { $failures.Add("Неизвестное основание $parent у $($row.Id)") }
        $covered[$parent] = $true
    }
}
foreach ($id in $systemIds) {
    if (-not $covered.ContainsKey($id)) { $failures.Add("Нет уточнения ПО для $id") }
}
if ($systemIds.Count -eq 0 -or $softwareRows.Count -eq 0) {
    $failures.Add('Не найдены строки требований одного из уровней.')
}

$requiredDocuments = @(
    'docs/requirements/system.md', 'docs/requirements/software.md',
    'docs/configuration-management.md', 'docs/development-plan.md',
    'docs/requirements-standard.md', 'docs/open-questions.md'
)
foreach ($document in $requiredDocuments) {
    if (-not (Test-Path -LiteralPath (Join-Path $taskRepoRoot $document) -PathType Leaf)) {
        $failures.Add("Отсутствует документ: $document")
    }
}

$backlog = Get-Content -LiteralPath (Join-Path $taskRepoRoot 'docs/backlog.md') -Raw -Encoding UTF8
$taskSums = @{}
foreach ($match in [regex]::Matches($backlog, '(?m)^\| (E\d+)-\d+ \|[^\r\n]*?\| (\d+) \|')) {
    $taskSums[$match.Groups[1].Value] += [int]$match.Groups[2].Value
}
foreach ($match in [regex]::Matches($backlog, '(?m)^\| (E\d+) \|[^|]*\|[^|]*\| (\d+) \|')) {
    $section = $match.Groups[1].Value
    if ($taskSums[$section] -ne [int]$match.Groups[2].Value) {
        $failures.Add("Оценка раздела $section не равна сумме его задач.")
    }
}
foreach ($match in [regex]::Matches($backlog, '(?m)^## (E\d+)\.[^\r\n]* — (\d+) SP')) {
    if ($taskSums[$match.Groups[1].Value] -ne [int]$match.Groups[2].Value) {
        $failures.Add("Оценка в заголовке $($match.Groups[1].Value) не равна сумме задач.")
    }
}
$total = ($taskSums.Values | Measure-Object -Sum).Sum
$statedTotal = [regex]::Match($backlog, '\| \*\*Итого\*\* \| \| \*\*(\d+)\*\*')
$summary = ($backlog -split '## Сводка оценок и порядка', 2)[1]
$stageSum = 0
foreach ($match in [regex]::Matches($summary, '(?m)^\|[^|]*\|[^|]*\| (\d+) \|')) {
    $stageSum += [int]$match.Groups[1].Value
}
if (-not $statedTotal.Success -or $total -ne [int]$statedTotal.Groups[1].Value -or $total -ne $stageSum) {
    $failures.Add('Общий итог или сумма групп этапов не совпадает с суммой задач.')
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Output $_ }
    exit 1
}
Write-Output "Проверено документов: $($markdownFiles.Count); ссылок на файлы: $linkCount; системных требований: $($systemIds.Count); требований к ПО: $($softwareRows.Count)."
Write-Output 'Номера уникальны; ссылки разрешаются; каждое системное требование имеет уточнение ПО.'
Write-Output "Суммы задач, разделов и групп этапов совпадают: $total условные единицы."
Write-Output 'Смысловая полнота, внешние страницы и поведение приложения этой проверкой не устанавливаются.'
