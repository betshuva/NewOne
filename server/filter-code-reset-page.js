'use strict';
module.exports = nonce => `<!doctype html>
<html lang="he" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>קוד נעילה חדש – בתשובה</title>
<style nonce="${nonce}">
*{box-sizing:border-box}body{font-family:Arial,sans-serif;background:#edf5fd;margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}.card{background:white;border-radius:20px;padding:28px;width:100%;max-width:400px;box-shadow:0 6px 24px #0d213715}h1{font-size:24px;margin-top:0;color:#1b6faa}p{line-height:1.5}label{display:block;margin:16px 0 6px}input{width:100%;padding:12px;border:1px solid #afc9da;border-radius:10px;font-size:22px;text-align:center;direction:ltr}button{width:100%;margin-top:20px;padding:13px;border:0;border-radius:10px;background:#1b6faa;color:white;font-size:16px;cursor:pointer}button:disabled{opacity:.6;cursor:default}#message{margin-top:16px;line-height:1.5;color:#b71c1c}#message.success{color:#2e7d32}a{display:inline-block;margin-top:18px;color:#1b6faa}
</style></head><body><main class="card"><h1>בחירת קוד נעילה חדש</h1><p>הזינו קוד חדש בן 4–8 ספרות ואשרו אותו בשנית.</p>
<form id="form"><label for="pin">קוד חדש</label><input id="pin" name="pin" type="password" inputmode="numeric" pattern="[0-9]{4,8}" minlength="4" maxlength="8" autocomplete="new-password" required>
<label for="confirm">הזינו שוב את הקוד החדש</label><input id="confirm" name="confirm" type="password" inputmode="numeric" pattern="[0-9]{4,8}" minlength="4" maxlength="8" autocomplete="new-password" required><button id="save" type="submit">שמירת הקוד החדש</button></form><div id="message" role="status" aria-live="polite"></div><a href="./">חזרה לבתשובה</a></main>
<script nonce="${nonce}">
const token=new URLSearchParams(location.hash.slice(1)).get('token')||'';
history.replaceState(null,'',location.pathname);
const form=document.getElementById('form'),message=document.getElementById('message'),button=document.getElementById('save');
if(!/^[a-f0-9]{64}$/.test(token)){form.hidden=true;message.textContent='הקישור אינו תקף. בקשו קישור חדש באמצעות ״שכחתי קוד״.';}
form.addEventListener('submit',async event=>{
 event.preventDefault();
 const pin=document.getElementById('pin').value,confirmPin=document.getElementById('confirm').value;
 if(!/^[0-9]{4,8}$/.test(pin)){message.textContent='יש לבחור קוד בן 4–8 ספרות';return;}
 if(pin!==confirmPin){message.textContent='הקודים אינם תואמים';return;}
 button.disabled=true;message.textContent='';
 try{
  const response=await fetch('api/filter-pin/reset-link',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token,pin,confirmPin})});
  const data=await response.json();
  if(!response.ok)throw new Error(data.error||'לא ניתן לעדכן את הקוד כעת');
  form.reset();form.hidden=true;message.className='success';message.textContent='הקוד החדש נשמר בהצלחה. תוכלו להשתמש בו לפתיחת הגדרות הסינון.';
 }catch(error){message.textContent=error.message||'לא ניתן לעדכן את הקוד כעת';button.disabled=false;}
});
</script></body></html>`;
