#!/bin/bash

# Инициализация и строгий режим
set -euo pipefail
trap 'echo "Ошибка на строке $LINENO. Завершение с кодом $?" >&2; exit 1' ERR

# Исправление прерванных установок пакетов
fix_interrupted_package_installation() {
    echo "Проверка и исправление прерванных установок пакетов..."
    sudo dpkg --configure -a
    echo "Прерванные установки пакетов исправлены."
}

# Вызов функции исправления прерванных установок в самом начале
fix_interrupted_package_installation

# Загрузка переменных среды
ENV_FILE="/srv/talknet/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "Файл с переменными среды $ENV_FILE не найден, завершение..."
    exit 1
fi

# Пути к каталогам
mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$FLASK_APP_DIR"

# Настройка файла журнала
LOG_FILE="$LOG_DIR/deploy.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Начало развёртывания: $(date)"

# Поворот журналов
rotate_logs() {
    find "$LOG_DIR" -type f -name '*.log' -mtime +30 -exec rm {} \;
    echo "Старые журналы очищены."
}

# Жесткая установка PostgreSQL
install_postgresql() {
    echo "Установка PostgreSQL..."

    sudo apt-get remove --purge -qq -y "postgresql-14" "postgresql-contrib-14"
    sudo rm -rf /var/lib/postgresql/
    sudo apt-get install -qq -y "postgresql-14" "postgresql-contrib-14"
    echo "PostgreSQL успешно установлен."
}

# Инициализация кластера базы данных PostgreSQL
init_db_cluster() {
    sudo pg_dropcluster --stop 14 main || true
    sudo pg_createcluster 14 main --start
    echo "Кластер PostgreSQL инициализирован."
}

# Настройка PostgreSQL для приема подключений
configure_postgresql() {
    sudo sed -i "/^#listen_addresses = 'localhost'/c\listen_addresses = '*'" "/etc/postgresql/14/main/postgresql.conf"
    sudo sed -i "/^#port = 5432/c\port = 5432" "/etc/postgresql/14/main/postgresql.conf"
    echo "host all all $PG_HOST md5" | sudo tee -a "/etc/postgresql/14/main/pg_hba.conf"
    sudo systemctl restart postgresql
    echo "PostgreSQL настроен для приема подключений."
}


# Создание пользователя и базы данных PostgreSQL
create_db_user_and_database() {
    set +e # Отключаем прерывание скрипта при ошибках
    sudo -u postgres psql -c "CREATE USER $PG_USER WITH PASSWORD '$PG_PASSWORD';"
    if [ $? -ne 0 ]; then
        echo "Ошибка при создании пользователя $PG_USER."
    fi
    sudo -u postgres psql -c "CREATE DATABASE $PG_DB WITH OWNER $PG_USER;"
    if [ $? -ne 0 ]; then
        echo "Ошибка при создании базы данных $PG_DB."
    fi
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER;"
    if [ $? -ne 0 ]; then
        echo "Ошибка при назначении привилегий пользователю $PG_USER на базу данных $PG_DB."
    fi
    set -e # Включаем обратно прерывание скрипта при ошибках
    echo "База данных и пользователь созданы."
}


# Установка необходимых зависимостей
install_dependencies() {
    sudo apt-get update
    sudo apt-get install -y python3 python3-pip python3-venv git nginx
    echo "Зависимости установлены."
}

# Тестирование подключения к базе данных
test_db_connection() {
    if ! PGPASSWORD=$PG_PASSWORD psql -h $PG_HOST -U $PG_USER -d $PG_DB -c '\q'; then
        echo "Ошибка подключения к базе данных."
        exit 1
    else
        echo "Подключение к базе данных успешно."
    fi
}

# Применение схемы базы данных
apply_schema() {
    echo "Применение схемы базы данных..."
    SCHEMA_PATH="$FLASK_APP_DIR/database/schema.sql"
    if [ -f "$SCHEMA_PATH" ]; then
        sudo -u postgres psql -d "$PG_DB" -a -f "$SCHEMA_PATH"
        echo "Схема применена из $SCHEMA_PATH."
    else
        echo "Файл схемы не найден по пути $SCHEMA_PATH. Пожалуйста, проверьте путь и повторите попытку."
    fi
}

# Резервное копирование базы данных
backup_db() {
    BACKUP_FILE="$BACKUP_DIR/${PG_DB}_$(date +%Y-%m-%d_%H-%M-%S).sql"
    PGPASSWORD=$PG_PASSWORD pg_dump -h $PG_HOST -U $PG_USER $PG_DB > "$BACKUP_FILE"
    echo "База данных скопирована в $BACKUP_FILE."
}

# Обновление или клонирование репозитория
clone_update_repo() {
    if [ -d "$FLASK_APP_DIR/.git" ]; then
        cd "$FLASK_APP_DIR" && git fetch --all && git reset --hard $REPO_BRANCH
    else
        git clone $REPO_URL "$FLASK_APP_DIR" && cd "$FLASK_APP_DIR"
        git checkout $REPO_BRANCH
    fi
    echo "Репозиторий обновлен."
}

# Настройка виртуального окружения Python и установка зависимостей
setup_venv() {
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    pip install -r "$FLASK_APP_DIR/requirements.txt"
    echo "Зависимости установлены."
}

# Применение миграций базы данных Flask
apply_migrations() {
    echo "Применение миграций базы данных Flask..."
    source "$VENV_DIR/bin/activate"
    export FLASK_APP="$FLASK_APP_DIR/app.py"  # Адаптировать под точку входа вашего приложения Flask

    if [ ! -d "$FLASK_APP_DIR/migrations" ]; then
        flask db init
    fi

    flask db migrate -m "Автоматически сгенерированная миграция."
    flask db upgrade || echo "Нет миграций для применения или миграция не удалась."
}


# Перезапуск приложения Flask и Nginx
restart_services() {
    pkill gunicorn || true
    cd "$FLASK_APP_DIR"
    gunicorn --workers $GUNICORN_WORKERS --bind $GUNICORN_BIND "app:create_app()" --daemon
    sudo systemctl restart nginx
    echo "Приложение Flask и Nginx перезапущены."
}

# Основная логика
rotate_logs
install_dependencies
install_postgresql
init_db_cluster
configure_postgresql
create_db_user_and_database
test_db_connection
backup_db
clone_update_repo
setup_venv
apply_schema
apply_migrations
restart_services

echo "Развёртывание завершено: $(date)"
