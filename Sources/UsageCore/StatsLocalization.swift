import Foundation

// Cost and usage statistics texts (0.8.0), complete in all ten interface languages.
let statsTranslations: [String: [String: String]] = [
    "statsApiEquivalent": ["en": "≈ %@ equivalent API price", "zh-Hant": "≈ %@ 等值 API 價格", "zh-Hans": "≈ %@ 等值 API 价格", "ja": "API 換算 ≈ %@", "ko": "API 환산 ≈ %@", "es": "≈ %@ al precio de la API", "fr": "≈ %@ au tarif de l’API", "de": "≈ %@ zum API-Preis", "pt-BR": "≈ %@ no preço da API", "it": "≈ %@ al prezzo dell’API"],
    "statsApiNote": ["en": "List-price equivalent: subscription users do not pay this. Only models with a known price are counted.", "zh-Hant": "依公開定價換算，訂閱方案使用者並不需要支付。只計入已知價格的模型。", "zh-Hans": "按公开定价换算，订阅方案用户并不需要支付。只计入已知价格的模型。", "ja": "公開価格での換算額です。サブスクリプション利用者が支払う金額ではありません。価格が分かるモデルのみ集計します。", "ko": "공개 가격 기준 환산액이며 구독 사용자는 지불하지 않습니다. 가격이 확인된 모델만 포함합니다.", "es": "Equivalente a precio de lista: quienes usan una suscripción no pagan esto. Solo cuentan los modelos con precio conocido.", "fr": "Équivalent au tarif public : les abonnés ne paient pas cette somme. Seuls les modèles dont le prix est connu sont comptés.", "de": "Gegenwert zum Listenpreis: Abo-Nutzer zahlen das nicht. Nur Modelle mit bekanntem Preis werden gezählt.", "pt-BR": "Equivalente ao preço de tabela: quem usa assinatura não paga isso. Só entram modelos com preço conhecido.", "it": "Equivalente al prezzo di listino: chi ha un abbonamento non lo paga. Contano solo i modelli con prezzo noto."],
    "statsCacheHit": ["en": "Cache hit rate", "zh-Hant": "快取命中率", "zh-Hans": "缓存命中率", "ja": "キャッシュヒット率", "ko": "캐시 적중률", "es": "Tasa de aciertos de caché", "fr": "Taux de succès du cache", "de": "Cache-Trefferquote", "pt-BR": "Taxa de acerto do cache", "it": "Percentuale di cache hit"],
    "statsCacheSaved": ["en": "saves ≈ %@ versus no cache", "zh-Hant": "比不使用快取省下約 %@", "zh-Hans": "比不使用缓存省下约 %@", "ja": "キャッシュなしより約 %@ 節約", "ko": "캐시가 없을 때보다 약 %@ 절약", "es": "ahorra ≈ %@ frente a no usar caché", "fr": "économise ≈ %@ par rapport à l’absence de cache", "de": "spart ≈ %@ gegenüber ohne Cache", "pt-BR": "economiza ≈ %@ em relação a sem cache", "it": "risparmia ≈ %@ rispetto a nessuna cache"],
    "statsTokenShare": ["en": "Where the tokens went", "zh-Hant": "Token 去向", "zh-Hans": "Token 去向", "ja": "トークンの内訳", "ko": "토큰 구성", "es": "Reparto de tokens", "fr": "Répartition des tokens", "de": "Token-Verteilung", "pt-BR": "Distribuição de tokens", "it": "Ripartizione dei token"],
    "catCacheRead": ["en": "cache read", "zh-Hant": "快取讀取", "zh-Hans": "缓存读取", "ja": "キャッシュ読み取り", "ko": "캐시 읽기", "es": "lectura de caché", "fr": "lecture du cache", "de": "Cache-Lesen", "pt-BR": "leitura de cache", "it": "lettura cache"],
    "catNewInput": ["en": "new input (incl. cache writes)", "zh-Hant": "新輸入（含快取寫入）", "zh-Hans": "新输入（含缓存写入）", "ja": "新規入力（キャッシュ書き込み含む）", "ko": "새 입력(캐시 쓰기 포함)", "es": "entrada nueva (con escrituras de caché)", "fr": "nouvelle entrée (écritures de cache incluses)", "de": "neue Eingabe (inkl. Cache-Schreiben)", "pt-BR": "entrada nova (com gravações de cache)", "it": "nuovo input (incl. scritture cache)"],
    "catOutput": ["en": "output (excl. reasoning)", "zh-Hant": "輸出（不含推理）", "zh-Hans": "输出（不含推理）", "ja": "出力（推論を除く）", "ko": "출력(추론 제외)", "es": "salida (sin razonamiento)", "fr": "sortie (hors raisonnement)", "de": "Ausgabe (ohne Reasoning)", "pt-BR": "saída (sem raciocínio)", "it": "output (escluso ragionamento)"],
    "catReasoning": ["en": "reasoning", "zh-Hant": "推理", "zh-Hans": "推理", "ja": "推論", "ko": "추론", "es": "razonamiento", "fr": "raisonnement", "de": "Reasoning", "pt-BR": "raciocínio", "it": "ragionamento"],
    "statsByAgent": ["en": "By agent", "zh-Hant": "依 agent", "zh-Hans": "按 agent", "ja": "エージェント別", "ko": "에이전트별", "es": "Por agente", "fr": "Par agent", "de": "Nach Agent", "pt-BR": "Por agente", "it": "Per agente"],
    "statsByModel": ["en": "By model", "zh-Hant": "依模型", "zh-Hans": "按模型", "ja": "モデル別", "ko": "모델별", "es": "Por modelo", "fr": "Par modèle", "de": "Nach Modell", "pt-BR": "Por modelo", "it": "Per modello"],
    "statsCalls": ["en": "%@ calls", "zh-Hant": "%@ 次呼叫", "zh-Hans": "%@ 次调用", "ja": "%@ 回の呼び出し", "ko": "호출 %@회", "es": "%@ llamadas", "fr": "%@ appels", "de": "%@ Aufrufe", "pt-BR": "%@ chamadas", "it": "%@ chiamate"],
    "statsActive": ["en": "active ≈ %@ (approx.)", "zh-Hant": "活躍時間約 %@（估計）", "zh-Hans": "活跃时间约 %@（估算）", "ja": "稼働時間 ≈ %@（概算）", "ko": "활동 시간 ≈ %@(추정)", "es": "tiempo activo ≈ %@ (aprox.)", "fr": "temps actif ≈ %@ (approx.)", "de": "aktive Zeit ≈ %@ (ca.)", "pt-BR": "tempo ativo ≈ %@ (aprox.)", "it": "tempo attivo ≈ %@ (circa)"],
    "statsActiveHelp": ["en": "Active time counts each 5-minute slot that has any model call as 5 minutes, so it is approximate.", "zh-Hant": "活躍時間把每個有模型呼叫的 5 分鐘區段算作 5 分鐘，因此只是估計值。", "zh-Hans": "活跃时间把每个有模型调用的 5 分钟区段算作 5 分钟，因此只是估算值。", "ja": "稼働時間は、モデル呼び出しがあった 5 分ごとの枠を 5 分として数えるため概算です。", "ko": "활동 시간은 모델 호출이 있었던 5분 구간을 각각 5분으로 계산하므로 추정치입니다.", "es": "El tiempo activo cuenta como 5 minutos cada tramo de 5 minutos con alguna llamada, así que es aproximado.", "fr": "Le temps actif compte pour 5 minutes chaque tranche de 5 minutes avec au moins un appel, il est donc approximatif.", "de": "Die aktive Zeit zählt jedes 5-Minuten-Fenster mit mindestens einem Aufruf als 5 Minuten und ist daher ungefähr.", "pt-BR": "O tempo ativo conta cada intervalo de 5 minutos com alguma chamada como 5 minutos, então é aproximado.", "it": "Il tempo attivo conta come 5 minuti ogni intervallo di 5 minuti con almeno una chiamata, quindi è approssimativo."],
    "statsNotPriced": ["en": "not priced", "zh-Hant": "未定價", "zh-Hans": "未定价", "ja": "価格不明", "ko": "가격 없음", "es": "sin precio", "fr": "prix inconnu", "de": "ohne Preis", "pt-BR": "sem preço", "it": "senza prezzo"],
    "statsLocal": ["en": "Local", "zh-Hant": "本機", "zh-Hans": "本机", "ja": "ローカル", "ko": "로컬", "es": "Local", "fr": "Local", "de": "Lokal", "pt-BR": "Local", "it": "Locale"],
    "statsUnpriced": ["en": "%@ tokens have no known price and are not in the cost", "zh-Hant": "%@ 個 token 沒有已知價格，未計入費用", "zh-Hans": "%@ 个 token 没有已知价格，未计入费用", "ja": "%@ トークンは価格不明のため費用に含まれません", "ko": "%@ 토큰은 가격을 알 수 없어 비용에서 제외됩니다", "es": "%@ tokens sin precio conocido no cuentan en el coste", "fr": "%@ tokens sans prix connu ne sont pas dans le coût", "de": "%@ Tokens ohne bekannten Preis sind nicht in den Kosten enthalten", "pt-BR": "%@ tokens sem preço conhecido ficam fora do custo", "it": "%@ token senza prezzo noto non sono nel costo"],
    "statsUnknownModel": ["en": "unknown model", "zh-Hant": "未知模型", "zh-Hans": "未知模型", "ja": "不明なモデル", "ko": "알 수 없는 모델", "es": "modelo desconocido", "fr": "modèle inconnu", "de": "unbekanntes Modell", "pt-BR": "modelo desconhecido", "it": "modello sconosciuto"],
    "statsOtherModels": ["en": "other models", "zh-Hant": "其他模型", "zh-Hans": "其他模型", "ja": "その他のモデル", "ko": "기타 모델", "es": "otros modelos", "fr": "autres modèles", "de": "andere Modelle", "pt-BR": "outros modelos", "it": "altri modelli"],
    "menuTodayCost": ["en": "Today ≈ %@ API-equivalent", "zh-Hant": "今天 ≈ %@（API 等值）", "zh-Hans": "今天 ≈ %@（API 等值）", "ja": "今日 ≈ %@（API 換算）", "ko": "오늘 ≈ %@(API 환산)", "es": "Hoy ≈ %@ (equiv. API)", "fr": "Aujourd’hui ≈ %@ (équiv. API)", "de": "Heute ≈ %@ (API-Äquivalent)", "pt-BR": "Hoje ≈ %@ (equiv. API)", "it": "Oggi ≈ %@ (equiv. API)"],
]
extension L10n {
    /// "$12.34"; amounts under one cent read "<$0.01".
    public func usd(_ value: Double) -> String {
        if value > 0 && value < 0.005 { return "<$0.01" }
        return "$" + number(value, decimals: value >= 100 ? 0 : 2)
    }
    public func percent(_ share: Double) -> String {
        let value = share * 100
        return number(value, decimals: value > 0 && value < 10 ? 1 : 0) + "%"
    }
    /// "1h 25m" from minutes.
    public func activeTime(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        if h == 0 { return "\(m)\(text("minuteShort"))" }
        return m == 0 ? "\(h)\(text("hourShort"))" : "\(h)\(text("hourShort")) \(m)\(text("minuteShort"))"
    }
    public func categoryName(_ kind: UsageReport.Category.Kind) -> String {
        switch kind {
        case .cacheRead: return text("catCacheRead")
        case .newInput: return text("catNewInput")
        case .output: return text("catOutput")
        case .reasoning: return text("catReasoning")
        }
    }
    /// Model id as found in the log, or a label for unknown and folded models.
    public func modelName(_ line: UsageReport.Line) -> String {
        switch line.model {
        case nil: return text("statsUnknownModel")
        case .some(ModelKey.other): return text("statsOtherModels")
        case let model?: return model
        }
    }
    /// "$1.20", "Local" or "not priced".
    public func costText(_ line: UsageReport.Line) -> String {
        switch line.status {
        case .local: return text("statsLocal")
        case .notPriced: return text("statsNotPriced")
        case .priced: return usd(line.costUSD ?? 0)
        }
    }
}
