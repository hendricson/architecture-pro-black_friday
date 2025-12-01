# Задание 10. Миграция на Cassandra: модель данных, стратегии репликации и шардирования

## Контекст проблемы

При нагрузке **50 000 запросов/сек** в «чёрную пятницу»:
- MongoDB Range-Based Sharding требовал полного перераспределения данных при добавлении шардов
- Это вызывало просадку latency в пиковые моменты
- Ресурсы тратились на миграцию данных вместо обслуживания запросов

**Чем может помочь БД Cassandra:**
- Consistent Hashing — при добавлении узла перемещается только ~1/N данных
- Leaderless-архитектура — нет единой точки отказа
- Линейная масштабируемость — производительность растёт линейно с числом узлов

---

## 10.1. Анализ данных для миграции

### Критерии оценки

| Критерий | Cassandra подходит | Cassandra не подходит |
|----------|-------------------|----------------------|
| Паттерн доступа | Key-value, time-series | Ad-hoc queries, JOINs |
| Консистентность | Eventual consistency допустима | Необходима strong consistency |
| Запись | Высокая throughput | Редкая, но атомарная |
| Чтение | По известному ключу | Сложные фильтры, агрегации |
| Масштаб | Терабайты, geo-distributed | Небольшие данные |

### Анализ сущностей магазина

| Сущность | Частота записи | Паттерн чтения | Консистентность | Cassandra? |
|----------|----------------|----------------|-----------------|------------|
| **Сессии пользователей** | Очень высокая | По session_id | Eventual consistency допустима | Да |
| **Корзины** | Высокая | По cart_id/user_id | Eventual consistency допустима* | Да |
| **История заказов** | Append-only | По customer_id + время | Eventual consistency допустима | Да |
| **Каталог товаров** | Низкая | Поиск, фильтры | Eventual consistency допустима | Частично |
| **Активные заказы** | Средняя | Статусы, workflow | Необходима strong consistency | Нет |
| **Остатки на складе** | При покупке | Проверка наличия | Необходима strong consistency | Нет |

### Решение по миграции

см. файл [migration-architecture.drawio](migration-architecture.drawio)

### Обоснование выбора

#### Сессии пользователей -> Cassandra

| Фактор | Почему подходит |
|--------|-----------------|
| **Высокая частота записи** | Каждый запрос пользователя обновляет сессию |
| **Простой доступ** | Всегда по `session_id` |
| **TTL** | Встроенная поддержка автоудаления |
| **Гео-распределение** | Сессия должна быть доступна в любом регионе |
| **Eventual consistency** | Потеря последних секунд сессии некритична |

#### Корзины -> Cassandra

| Фактор | Почему подходит |
|--------|-----------------|
| **Высокая частота записи** | Частые добавления/удаления товаров |
| **Простой доступ** | По `user_id` или `session_id` |
| **TTL** | Автоочистка брошенных корзин |
| **Масштабирование** | Black Friday: миллионы активных корзин |

*Примечание: при оформлении заказа корзина читается с `QUORUM` для консистентности.

#### История заказов -> Cassandra

| Фактор | Почему подходит |
|--------|-----------------|
| **Append-only** | Заказы не изменяются после завершения |
| **Time-series** | Естественная сортировка по времени |
| **Большой объём** | Годы истории, терабайты данных |
| **Простой доступ** | «Покажи заказы клиента X за период Y» |

#### Активные заказы -> MongoDB

| Фактор | Почему НЕ подходит для Cassandra |
|--------|----------------------------------|
| **Workflow** | Сложная логика смены статусов |
| **Транзакции** | Связь с платёжной системой |
| **Strong consistency** | Нельзя потерять/дублировать заказ |
| **Частые изменения** | Обновления одной записи |

#### Остатки на складе -> MongoDB

| Фактор | Почему НЕ подходит для Cassandra |
|--------|----------------------------------|
| **Race conditions** | Параллельные покупки одного товара |
| **Атомарные операции** | `$inc: { stock: -1 }` должен быть атомарным |
| **Strong consistency** | Риск overselling |

---

## 10.2. Концептуальная модель Cassandra

### Принципы моделирования

В Cassandra модель строится от запросов, а не от сущностей:

```
MongoDB:  Entity -> Normalize -> Query (любой)
Cassandra: Query -> Denormalize -> Table (под конкретный запрос)
```

### Таблица: user_sessions (сессии пользователей)

**Запрос:** Получить сессию по session_id

```cql
CREATE TABLE user_sessions (
    session_id      TEXT,
    user_id         UUID,
    created_at      TIMESTAMP,
    last_activity   TIMESTAMP,
    ip_address      TEXT,
    user_agent      TEXT,
    cart_id         UUID,
    preferences     MAP<TEXT, TEXT>,
    
    PRIMARY KEY (session_id)
) WITH default_time_to_live = 86400    -- TTL 24 часа
  AND gc_grace_seconds = 3600;
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| **Partition Key** | `session_id` | Уникален, равномерное распределение |
| **Clustering Key** | нет | Одна строка на сессию |

**Почему нет hot partitions:**
- `session_id` генерируется как UUID/random string
- Каждая сессия на отдельной партиции
- Нагрузка распределяется равномерно по кластеру

### Таблица: shopping_carts (корзины)

**Запрос:** Получить корзину пользователя со всеми товарами

```cql
CREATE TABLE shopping_carts (
    cart_id         UUID,
    user_id         UUID,
    session_id      TEXT,
    product_id      UUID,
    product_name    TEXT,          -- денормализация
    product_price   DECIMAL,       -- денормализация
    quantity        INT,
    added_at        TIMESTAMP,
    
    PRIMARY KEY (cart_id, product_id)
) WITH default_time_to_live = 604800   -- TTL 7 дней
  AND gc_grace_seconds = 86400;
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| **Partition Key** | `cart_id` | Все товары корзины на одной партиции |
| **Clustering Key** | `product_id` | Уникальность товара в корзине |

**Денормализация:** `product_name`, `product_price` хранятся в корзине, чтобы избежать JOIN с products.

### Таблица: orders_by_customer (история заказов)

**Запрос:** История заказов клиента (последние первыми)

```cql
CREATE TABLE orders_by_customer (
    customer_id     UUID,
    order_date      DATE,
    order_id        UUID,
    order_time      TIMESTAMP,
    status          TEXT,
    total_amount    DECIMAL,
    items_count     INT,
    delivery_address TEXT,

    PRIMARY KEY ((customer_id), order_date, order_id)
) WITH CLUSTERING ORDER BY (order_date DESC, order_id DESC);
```

| Ключ | Значение | Обоснование |
|------|----------|-------------|
| **Partition Key** | `customer_id` | Все заказы клиента вместе |
| **Clustering Key** | `order_date DESC, order_id` | Сортировка по дате |

**Риск hot partition:** VIP-клиенты с тысячами заказов.

**Решение:** Bucket по году

```cql
CREATE TABLE orders_by_customer_year (
    customer_id     UUID,
    year            INT,
    order_date      DATE,
    order_id        UUID,
    ...
    PRIMARY KEY ((customer_id, year), order_date, order_id)
) WITH CLUSTERING ORDER BY (order_date DESC, order_id DESC);
```

Теперь партиция = клиент + год -> ограниченный размер.

### Таблица: order_items (товары в заказе)

**Запрос:** Детали заказа (товары)

```cql
CREATE TABLE order_items (
    order_id        UUID,
    item_index      INT,
    product_id      UUID,
    product_name    TEXT,
    quantity        INT,
    unit_price      DECIMAL,
    total_price     DECIMAL,

    PRIMARY KEY (order_id, item_index)
);
```

### Сводная таблица ключей

| Таблица | Сущность | Partition Key | Clustering Key | Размер партиции |
|---------|----------|---------------|----------------|-----------------|
| `user_sessions` | Сессии | `session_id` | — | 1 строка |
| `shopping_carts` | Корзины | `cart_id` | `product_id` | ~10-50 строк |
| `orders_by_customer` | История заказов | `customer_id` | `order_date, order_id` | ~100-1000 строк |
| `orders_by_customer_year` | История заказов (с bucketing) | `customer_id, year` | `order_date, order_id` | ~10-100 строк |
| `order_items` | Товары в заказе | `order_id` | `item_index` | ~5-20 строк |

---

## 10.3. Стратегии обеспечения целостности данных

### Обзор стратегий

| Стратегия | Когда работает | Latency impact | Гарантия |
|-----------|---------------|----------------|----------|
| **Hinted Handoff («Передача с подсказкой»)** | Узел временно недоступен | Низкий | Слабая |
| **Read Repair** | При чтении обнаружена рассогласованность | Средний | Средняя |
| **Anti-Entropy Repair** | Фоновый процесс | Высокий (background) | Сильная |

### Hinted Handoff («Передача с подсказкой»)

Пример: узел B временно недоступен

1. Client отправляет запись через Coordinator (Node A)
2. Coordinator пытается записать на 3 узла:
   - Node A: OK (записано)
   - Node B: FAIL (недоступен) → hint сохранён на A
   - Node C: OK (записано)
3. Когда Node B возвращается, Node A передаёт ему пропущенные данные

**Настройка:**
```yaml
# cassandra.yaml
hinted_handoff_enabled: true
max_hint_window_in_ms: 10800000  # 3 часа
```

### Read Repair (восстановление согласованности при чтении)

Пример: client читает с CL=QUORUM

1. Coordinator опрашивает 3 узла:
   - Node A: version=5
   - Node B: version=5
   - Node C: version=3 (устарел)
2. Coordinator видит расхождение версий
3. Coordinator отправляет Node C актуальную версию (version=5)

**Настройка:**
```cql
ALTER TABLE user_sessions
WITH read_repair = 'BLOCKING';    -- или 'NONE'
```

### Anti-Entropy Repair (процесс сравнения и синхронизации реплик)

Фоновый процесс сравнения Merkle trees между репликами:

```bash
# Запуск repair для keyspace
nodetool repair shop_keyspace

# Инкрементальный repair (быстрее)
nodetool repair -pr shop_keyspace
```

**Рекомендация:** запускать раз в `gc_grace_seconds` (обычно 10 дней).

---

### Выбор стратегий по сущностям

#### user_sessions (сессии)

| Стратегия | Использовать | Обоснование |
|-----------|--------------|-------------|
| Hinted Handoff | Да | Быстрое восстановление при кратких сбоях |
| Read Repair | Да (BLOCKING) | Автокоррекция при каждом чтении |
| Anti-Entropy Repair | Редко | TTL=24h, данные быстро устаревают |

```cql
ALTER TABLE user_sessions
WITH read_repair = 'BLOCKING'
 AND gc_grace_seconds = 3600;   -- 1 час (короткий TTL)
```

**Consistency Level:**
- Write: `ONE` или `LOCAL_QUORUM` (скорость важнее)
- Read: `ONE` (eventual consistency OK)

#### shopping_carts (корзины)

| Стратегия | Использовать | Обоснование |
|-----------|--------------|-------------|
| Hinted Handoff | Да | Не потерять товары при сбое узла |
| Read Repair | Да (BLOCKING) | Корзина должна быть актуальной |
| Anti-Entropy Repair | Еженедельно | TTL=7d, нужна периодическая проверка |

```cql
ALTER TABLE shopping_carts
WITH read_repair = 'BLOCKING'
 AND gc_grace_seconds = 86400;  -- 1 день
```

**Consistency Level:**
- Write: `LOCAL_QUORUM` (баланс скорости и надёжности)
- Read (просмотр): `ONE`
- Read (checkout): `QUORUM` (критично при оформлении заказа!)

#### orders_by_customer (история заказов)

| Стратегия | Использовать | Обоснование |
|-----------|--------------|-------------|
| Hinted Handoff | Да | Стандартная защита |
| Read Repair | Да (BLOCKING) | Автокоррекция |
| Anti-Entropy Repair | Еженедельно | Данные хранятся годами, важна целостность |

```cql
ALTER TABLE orders_by_customer
WITH read_repair = 'BLOCKING'
 AND gc_grace_seconds = 864000;  -- 10 дней (стандарт)
```

**Consistency Level:**
- Write: `QUORUM` (заказ нельзя потерять!)
- Read: `ONE` (история редко меняется)

---

### Сводная таблица стратегий

| Таблица | Сущность | Hinted Handoff | Read Repair | Anti-Entropy Repair | Write CL | Read CL |
|---------|----------|---------------|-------------|---------------------|----------|---------|
| `user_sessions` | Сессии | | BLOCKING | Редко | ONE | ONE |
| `shopping_carts` | Корзины | | BLOCKING | Еженедельно | LOCAL_QUORUM | ONE / QUORUM* |
| `orders_by_customer` | История заказов | | BLOCKING | Еженедельно | QUORUM | ONE |
| `order_items` | Товары в заказе | | BLOCKING | Еженедельно | QUORUM | ONE |

*QUORUM при оформлении заказа (checkout)

---

## Диаграмма архитектуры

См. файл [geo-architecture.drawio](geo-architecture.drawio)

---

## Преимущества при масштабировании

### MongoDB: добавление 4-го шарда (Range-Based Sharding)

| Шард | До | После | Перемещение |
|------|-----|-------|-------------|
| Shard1 | 33% | 25% | отдаёт 8% |
| Shard2 | 33% | 25% | отдаёт 8% |
| Shard3 | 33% | 25% | отдаёт 8% |
| Shard4 | 0% | 25% | получает 8% × 3 = 24% |

**Итого:** перемещается ~24% всех данных (каждый шард отдаёт часть новому).
Время: часы. Latency spike во время балансировки.

### Cassandra: добавление 4-го узла (Consistent Hashing)

| Узел | До | После | Перемещение |
|------|-----|-------|-------------|
| Node1 | 33% | 25% | отдаёт 8% соседу |
| Node2 | 33% | 33% | без изменений |
| Node3 | 33% | 33% | без изменений |
| Node4 | 0% | 8% | получает только от Node1 |

**Итого:** перемещается ~8% данных (только от одного соседа по кольцу).
Время: минуты. Минимальное влияние на latency.

