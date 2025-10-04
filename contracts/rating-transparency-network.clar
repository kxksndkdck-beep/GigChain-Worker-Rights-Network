;; rating-transparency-network
;; Prevent unfair rating manipulation and provide transparent feedback systems for workers

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-RATING-NOT-FOUND (err u301))
(define-constant ERR-INVALID-RATING (err u302))
(define-constant ERR-ALREADY-RATED (err u303))
(define-constant ERR-WORKER-NOT-FOUND (err u304))
(define-constant ERR-CLIENT-NOT-FOUND (err u305))
(define-constant ERR-INSUFFICIENT-CREDIBILITY (err u306))
(define-constant ERR-MANIPULATION-DETECTED (err u307))
(define-constant ERR-REVIEW-TOO-LONG (err u308))
(define-constant ERR-CHALLENGE-EXISTS (err u309))
(define-constant ERR-CHALLENGE-WINDOW-CLOSED (err u310))
(define-constant ERR-INVALID-CHALLENGE (err u311))
(define-constant ERR-VALIDATOR-NOT_QUALIFIED (err u312))

(define-constant MIN-RATING u1)
(define-constant MAX-RATING u5)
(define-constant MAX-REVIEW-LENGTH u1000)
(define-constant MIN-CREDIBILITY-SCORE u50)
(define-constant CHALLENGE-WINDOW-BLOCKS u144) ;; ~24 hours
(define-constant VALIDATION-THRESHOLD u3) ;; 3 validators needed
(define-constant MANIPULATION-PENALTY u500) ;; 500 micro-STX penalty
(define-constant VALIDATOR-REWARD u100) ;; 100 micro-STX reward

;; Data Maps
(define-map ratings
  { rating-id: uint }
  {
    worker: principal,
    client: principal,
    gig-id: uint,
    rating-score: uint,
    review-text: (string-ascii 1000),
    submitted-at: uint,
    platform: (string-ascii 50),
    gig-category: (string-ascii 50),
    is-verified: bool,
    credibility-score: uint,
    challenge-count: uint,
    validation-score: uint
  }
)

(define-map client-credibility
  { client: principal }
  {
    total-ratings-given: uint,
    credibility-score: uint,
    last-updated: uint,
    manipulation-flags: uint,
    verified-ratings: uint,
    average-rating-given: uint
  }
)

(define-map worker-rating-stats
  { worker: principal }
  {
    total-ratings: uint,
    average-rating: uint,
    rating-distribution: (list 5 uint), ;; [1-star, 2-star, 3-star, 4-star, 5-star]
    verified-rating-count: uint,
    last-rating-at: uint,
    credibility-weighted-average: uint
  }
)

(define-map rating-challenges
  { rating-id: uint, challenger: principal }
  {
    challenge-reason: (string-ascii 500),
    challenged-at: uint,
    evidence: (string-ascii 1000),
    status: (string-ascii 20),
    validator-votes: uint,
    resolution: (optional (string-ascii 20))
  }
)

(define-map validators
  { validator: principal }
  {
    active: bool,
    validation-count: uint,
    accuracy-score: uint,
    stake-amount: uint,
    last-activity: uint
  }
)

(define-map platform-ratings
  { platform: (string-ascii 50) }
  {
    total-ratings: uint,
    average-rating: uint,
    fairness-score: uint,
    manipulation-incidents: uint,
    last-updated: uint
  }
)

(define-map rating-metadata
  { rating-id: uint }
  {
    gig-duration: uint,
    payment-amount: uint,
    completion-time: uint,
    complexity-level: uint,
    communication-rating: uint,
    quality-rating: uint,
    timeliness-rating: uint
  }
)

;; Data Variables
(define-data-var next-rating-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var total-ratings uint u0)
(define-data-var total-challenges uint u0)
(define-data-var manipulation-detection-threshold uint u80)

;; Private Functions
(define-private (is-valid-rating (rating uint))
  (and (>= rating MIN-RATING) (<= rating MAX-RATING))
)

(define-private (calculate-credibility-score (client principal))
  (let (
    (client-data (default-to 
      { total-ratings-given: u0, credibility-score: u100, last-updated: u0, manipulation-flags: u0, verified-ratings: u0, average-rating-given: u0 }
      (map-get? client-credibility { client: client })
    ))
    (base-score u100)
    (rating-count (get total-ratings-given client-data))
    (manipulation-flags (get manipulation-flags client-data))
    (verified-ratio (if (> rating-count u0) (/ (* (get verified-ratings client-data) u100) rating-count) u0))
  )
    ;; Higher credibility for more verified ratings, lower for manipulation flags
    (let (
      (adjusted-score (- base-score (* manipulation-flags u20)))
      (bonus-score (/ verified-ratio u10))
    )
      (if (> (+ adjusted-score bonus-score) u0)
        (+ adjusted-score bonus-score)
        u1
      )
    )
  )
)

(define-private (detect-manipulation-patterns (client principal) (rating uint) (worker principal))
  (let (
    (client-data (map-get? client-credibility { client: client }))
    (recent-ratings (get-recent-client-ratings client))
  )
    (or
      ;; Pattern 1: Consistently extreme ratings (all 1s or all 5s)
      (is-rating-pattern-suspicious client rating)
      ;; Pattern 2: Rapid succession of ratings
      (is-rating-frequency-suspicious client)
      ;; Pattern 3: Rating the same worker multiple times
      (has-rated-worker-recently client worker)
    )
  )
)

(define-private (is-rating-pattern-suspicious (client principal) (rating uint))
  (let (
    (client-data (default-to 
      { total-ratings-given: u0, credibility-score: u100, last-updated: u0, manipulation-flags: u0, verified-ratings: u0, average-rating-given: u0 }
      (map-get? client-credibility { client: client })
    ))
    (avg-rating (get average-rating-given client-data))
    (rating-count (get total-ratings-given client-data))
  )
    (and 
      (> rating-count u5) ;; Only check if client has given more than 5 ratings
      (or 
        (and (is-eq rating u1) (< avg-rating u20)) ;; All very low ratings
        (and (is-eq rating u5) (> avg-rating u80)) ;; All very high ratings
      )
    )
  )
)

(define-private (is-rating-frequency-suspicious (client principal))
  (let (
    (client-data (map-get? client-credibility { client: client }))
  )
    (match client-data
      data (let (
        (time-since-last (- stacks-block-height (get last-updated data)))
        (rating-count (get total-ratings-given data))
      )
        ;; Suspicious if more than 10 ratings in last 144 blocks (~1 day)
        (and (< time-since-last u144) (> rating-count u10))
      )
      false
    )
  )
)

(define-private (has-rated-worker-recently (client principal) (worker principal))
  ;; This would require additional storage to track client-worker rating history
  ;; For simplicity, returning false in this implementation
  false
)

(define-private (get-recent-client-ratings (client principal))
  ;; Placeholder function - would return list of recent ratings by client
  (list)
)

(define-private (update-worker-rating-stats (worker principal) (new-rating uint) (is-verified bool))
  (let (
    (current-stats (default-to
      { total-ratings: u0, average-rating: u0, rating-distribution: (list u0 u0 u0 u0 u0), verified-rating-count: u0, last-rating-at: u0, credibility-weighted-average: u0 }
      (map-get? worker-rating-stats { worker: worker })
    ))
    (total-ratings (get total-ratings current-stats))
    (current-avg (get average-rating current-stats))
    (new-total (+ total-ratings u1))
    (new-average (/ (+ (* current-avg total-ratings) new-rating) new-total))
    (new-verified-count (if is-verified (+ (get verified-rating-count current-stats) u1) (get verified-rating-count current-stats)))
  )
    (map-set worker-rating-stats
      { worker: worker }
      (merge current-stats {
        total-ratings: new-total,
        average-rating: new-average,
        verified-rating-count: new-verified-count,
        last-rating-at: stacks-block-height
      })
    )
  )
)

(define-private (update-client-credibility (client principal) (rating uint))
  (let (
    (current-cred (default-to
      { total-ratings-given: u0, credibility-score: u100, last-updated: u0, manipulation-flags: u0, verified-ratings: u0, average-rating-given: u0 }
      (map-get? client-credibility { client: client })
    ))
    (total-given (get total-ratings-given current-cred))
    (current-avg (get average-rating-given current-cred))
    (new-total (+ total-given u1))
    (new-avg (/ (+ (* current-avg total-given) rating) new-total))
    (new-credibility (calculate-credibility-score client))
  )
    (map-set client-credibility
      { client: client }
      (merge current-cred {
        total-ratings-given: new-total,
        average-rating-given: new-avg,
        credibility-score: new-credibility,
        last-updated: stacks-block-height
      })
    )
  )
)

;; Public Functions
(define-public (submit-rating (worker principal) (gig-id uint) (rating-score uint) (review-text (string-ascii 1000)) (platform (string-ascii 50)) (gig-category (string-ascii 50)))
  (let (
    (rating-id (var-get next-rating-id))
    (client tx-sender)
    (credibility (calculate-credibility-score client))
    (is-manipulation (detect-manipulation-patterns client rating-score worker))
  )
    (asserts! (is-valid-rating rating-score) (err ERR-INVALID-RATING))
    (asserts! (<= (len review-text) MAX-REVIEW-LENGTH) (err ERR-REVIEW-TOO-LONG))
    (asserts! (not (is-eq client worker)) (err ERR-NOT-AUTHORIZED))
    (asserts! (not is-manipulation) (err ERR-MANIPULATION-DETECTED))
    (asserts! (>= credibility MIN-CREDIBILITY-SCORE) (err ERR-INSUFFICIENT-CREDIBILITY))
    
    ;; Create rating record
    (map-set ratings
      { rating-id: rating-id }
      {
        worker: worker,
        client: client,
        gig-id: gig-id,
        rating-score: rating-score,
        review-text: review-text,
        submitted-at: stacks-block-height,
        platform: platform,
        gig-category: gig-category,
        is-verified: false,
        credibility-score: credibility,
        challenge-count: u0,
        validation-score: u0
      }
    )
    
    ;; Update statistics
    (update-worker-rating-stats worker rating-score false)
    (update-client-credibility client rating-score)
    
    (var-set next-rating-id (+ rating-id u1))
    (var-set total-ratings (+ (var-get total-ratings) u1))
    
    (ok rating-id)
  )
)

(define-public (challenge-rating (rating-id uint) (challenge-reason (string-ascii 500)) (evidence (string-ascii 1000)))
  (let (
    (rating-data (unwrap! (map-get? ratings { rating-id: rating-id }) (err ERR-RATING-NOT-FOUND)))
    (challenger tx-sender)
  )
    (asserts! (not (is-eq challenger (get client rating-data))) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-none (map-get? rating-challenges { rating-id: rating-id, challenger: challenger })) (err ERR-CHALLENGE-EXISTS))
    (asserts! (< (- stacks-block-height (get submitted-at rating-data)) CHALLENGE-WINDOW-BLOCKS) (err ERR-CHALLENGE-WINDOW-CLOSED))
    
    (map-set rating-challenges
      { rating-id: rating-id, challenger: challenger }
      {
        challenge-reason: challenge-reason,
        challenged-at: stacks-block-height,
        evidence: evidence,
        status: "pending",
        validator-votes: u0,
        resolution: none
      }
    )
    
    ;; Update rating challenge count
    (map-set ratings
      { rating-id: rating-id }
      (merge rating-data {
        challenge-count: (+ (get challenge-count rating-data) u1)
      })
    )
    
    (var-set total-challenges (+ (var-get total-challenges) u1))
    (ok true)
  )
)

(define-public (validate-rating (rating-id uint) (challenger principal) (is-valid bool) (justification (string-ascii 500)))
  (let (
    (challenge-data (unwrap! (map-get? rating-challenges { rating-id: rating-id, challenger: challenger }) (err ERR-INVALID-CHALLENGE)))
    (validator tx-sender)
    (validator-data (unwrap! (map-get? validators { validator: validator }) (err ERR-VALIDATOR-NOT_QUALIFIED)))
  )
    (asserts! (get active validator-data) (err ERR-VALIDATOR-NOT_QUALIFIED))
    (asserts! (is-eq (get status challenge-data) "pending") (err ERR-INVALID-CHALLENGE))
    
    ;; Record validator decision and update challenge
    (let (
      (current-votes (get validator-votes challenge-data))
      (new-votes (+ current-votes u1))
      (resolution-status (if is-valid "upheld" "dismissed"))
    )
      (map-set rating-challenges
        { rating-id: rating-id, challenger: challenger }
        (merge challenge-data {
          validator-votes: new-votes,
          status: (if (>= new-votes VALIDATION-THRESHOLD) "resolved" "pending"),
          resolution: (if (>= new-votes VALIDATION-THRESHOLD) (some resolution-status) none)
        })
      )
      
      ;; Reward validator
      (try! (stx-transfer? VALIDATOR-REWARD (var-get contract-owner) validator))
      
      ;; Update validator stats
      (map-set validators
        { validator: validator }
        (merge validator-data {
          validation-count: (+ (get validation-count validator-data) u1),
          last-activity: stacks-block-height
        })
      )
    )
    
    (ok true)
  )
)

(define-public (register-validator (stake-amount uint))
  (begin
    (asserts! (>= stake-amount u1000) (err ERR-INVALID-RATING)) ;; Minimum stake
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    (map-set validators
      { validator: tx-sender }
      {
        active: true,
        validation-count: u0,
        accuracy-score: u100,
        stake-amount: stake-amount,
        last-activity: stacks-block-height
      }
    )
    (ok true)
  )
)

(define-public (verify-rating (rating-id uint))
  (let (
    (rating-data (unwrap! (map-get? ratings { rating-id: rating-id }) (err ERR-RATING-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    
    (map-set ratings
      { rating-id: rating-id }
      (merge rating-data { is-verified: true })
    )
    
    ;; Update worker stats with verification
    (update-worker-rating-stats (get worker rating-data) (get rating-score rating-data) true)
    (ok true)
  )
)

(define-public (add-rating-metadata (rating-id uint) (gig-duration uint) (payment-amount uint) (completion-time uint) (complexity-level uint) (communication-rating uint) (quality-rating uint) (timeliness-rating uint))
  (let (
    (rating-data (unwrap! (map-get? ratings { rating-id: rating-id }) (err ERR-RATING-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (get client rating-data)) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-valid-rating communication-rating) (err ERR-INVALID-RATING))
    (asserts! (is-valid-rating quality-rating) (err ERR-INVALID-RATING))
    (asserts! (is-valid-rating timeliness-rating) (err ERR-INVALID-RATING))
    
    (map-set rating-metadata
      { rating-id: rating-id }
      {
        gig-duration: gig-duration,
        payment-amount: payment-amount,
        completion-time: completion-time,
        complexity-level: complexity-level,
        communication-rating: communication-rating,
        quality-rating: quality-rating,
        timeliness-rating: timeliness-rating
      }
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-rating (rating-id uint))
  (map-get? ratings { rating-id: rating-id })
)

(define-read-only (get-worker-rating-stats (worker principal))
  (map-get? worker-rating-stats { worker: worker })
)

(define-read-only (get-client-credibility (client principal))
  (map-get? client-credibility { client: client })
)

(define-read-only (get-rating-challenge (rating-id uint) (challenger principal))
  (map-get? rating-challenges { rating-id: rating-id, challenger: challenger })
)

(define-read-only (get-validator-info (validator principal))
  (map-get? validators { validator: validator })
)

(define-read-only (get-platform-rating (platform (string-ascii 50)))
  (map-get? platform-ratings { platform: platform })
)

(define-read-only (get-rating-metadata (rating-id uint))
  (map-get? rating-metadata { rating-id: rating-id })
)

(define-read-only (get-network-stats)
  {
    total-ratings: (var-get total-ratings),
    total-challenges: (var-get total-challenges),
    next-rating-id: (var-get next-rating-id),
    manipulation-threshold: (var-get manipulation-detection-threshold)
  }
)

(define-read-only (calculate-worker-credibility-score (worker principal))
  (let (
    (stats (map-get? worker-rating-stats { worker: worker }))
  )
    (match stats
      data (let (
        (total-ratings (get total-ratings data))
        (verified-count (get verified-rating-count data))
        (avg-rating (get average-rating data))
      )
        (if (> total-ratings u0)
          (+ (* (/ verified-count total-ratings) u50) (* avg-rating u10))
          u0
        )
      )
      u0
    )
  )
)
