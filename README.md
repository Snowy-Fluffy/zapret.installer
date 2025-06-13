## Скрипт для автоматической установки и управления [zapret'ом](https://github.com/bol-van/zapret)

Облегчает установку и управление zapret'ом для новичков и тех, кто не хочет разбираться в его работе.  
Использует оригинальный [zapret от bol-van](https://github.com/bol-van/zapret) и бинарники из его релиза. Работает поверх него, создавая комфортную CLI-среду для всевозможного управления.  

Скрипт также клонирует [мой репозиторий](https://github.com/Snowy-Fluffy/zapret.cfgs), содержащий стратегии и списки хостов для zapret, которые помогут пользователю настроить его под себя и обходить блокировки с комфортом.  (Полностью на Русском языке!)

### Установка  

Для установки достаточно ввести одну команду:  
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Snowy-Fluffy/zapret.installer/refs/heads/main/installer.sh)"
```
(Должен быть установлен curl в системе)


После установки панель управления можно будет запустить из любого места, открыв терминал и прописав:  
```bash
zapret
```

На данный момент поддерживаются:  
- Debian-подобные  
- Fedora-подобные  
- Arch-подобные  
- Alt Linux
- Void  
- Gentoo
- Openwrt

Частичная поддержка ruinit, OpenRC и SysVinit  
(Systemd и procd полностью поддерживается и корректно работает).  

О всех багах и недочётах сообщайте в issues или в моём [Telegram-канале](https://t.me/linux_hi).  
Поддержка других init-систем и дистрибутивов будет добавлена в дальнейшем.  

Попробуйте также [zapret-discord-youtube-linux](https://github.com/Sergeydigl3/zapret-discord-youtube-linux) от Sergeydigl3 

### Скриншоты  
![Основное меню](https://github.com/user-attachments/assets/1c8d3f11-d357-4783-bb13-7eba735b52ae)
![Подменю](https://github.com/user-attachments/assets/4c5b0af1-64d3-486b-9d23-8c4611517e29)
 
