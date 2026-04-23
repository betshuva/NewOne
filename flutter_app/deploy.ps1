# deploy.ps1 - בנה והעלה את האפליקציה ל-betshuva.com

$APP = "C:\Users\yaniv\xo_app"
$REPO = "C:\Users\yaniv\NewOne"

Write-Host "הורד קוד עדכני..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/betshuva/NewOne/main/flutter_app/lib/main.dart" -OutFile "$APP\lib\main.dart"

Write-Host "בונה את האפליקציה..." -ForegroundColor Cyan
Set-Location $APP
flutter build web --base-href /

Write-Host "מעתיק קבצים לריפו..." -ForegroundColor Cyan
$src = "$APP\build\web"
Copy-Item "$src\index.html"              $REPO -Force
Copy-Item "$src\flutter.js"             $REPO -Force
Copy-Item "$src\flutter_bootstrap.js"   $REPO -Force
Copy-Item "$src\flutter_service_worker.js" $REPO -Force
Copy-Item "$src\main.dart.js"           $REPO -Force
Copy-Item "$src\manifest.json"          $REPO -Force
Copy-Item "$src\favicon.png"            $REPO -Force
Copy-Item "$src\version.json"           $REPO -Force
Copy-Item "$src\.last_build_id"         $REPO -Force
Copy-Item "$src\assets"   $REPO -Recurse -Force
Copy-Item "$src\canvaskit" $REPO -Recurse -Force
Copy-Item "$src\icons"    $REPO -Recurse -Force

Write-Host "מעלה ל-GitHub..." -ForegroundColor Cyan
Set-Location $REPO
git pull origin main --rebase
git add .
git commit -m "deploy: update Flutter web app"
git push origin main

Write-Host "הושלם! האתר יתעדכן תוך כ-2 דקות." -ForegroundColor Green
Write-Host "https://betshuva.com" -ForegroundColor Yellow
