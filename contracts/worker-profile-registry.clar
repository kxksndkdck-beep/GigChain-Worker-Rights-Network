;; worker-profile-registry
;; Portable worker profiles with skills, ratings, and work history across multiple platforms

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-WORKER-NOT-FOUND (err u101))
(define-constant ERR-INVALID-INPUT (err u102))
(define-constant ERR-ALREADY-EXISTS (err u103))
(define-constant ERR-INSUFFICIENT-BALANCE (err u104))
(define-constant ERR-INVALID-SKILL (err u105))
(define-constant ERR-MAX-SKILLS-REACHED (err u106))
(define-constant ERR-INVALID-RATING (err u107))
(define-constant ERR-WORK-HISTORY-NOT-FOUND (err u108))
(define-constant ERR-INVALID-PORTFOLIO (err u109))
(define-constant ERR-VERIFICATION-FAILED (err u110))

(define-constant MAX-SKILLS u20)
(define-constant MAX-NAME-LENGTH u50)
(define-constant MAX-DESCRIPTION-LENGTH u500)
(define-constant MIN-RATING u1)
(define-constant MAX-RATING u5)
(define-constant REGISTRATION-FEE u1000) ;; 1000 micro-STX

;; Data Maps
(define-map worker-profiles 
  { worker: principal }
  { 
    name: (string-ascii 50),
    description: (string-ascii 500),
    created-at: uint,
    updated-at: uint,
    total-gigs: uint,
    total-earnings: uint,
    average-rating: uint,
    rating-count: uint,
    is-verified: bool,
    portfolio-hash: (string-ascii 64),
    profile-status: (string-ascii 20)
  }
)

(define-map worker-skills
  { worker: principal, skill-id: uint }
  {
    skill-name: (string-ascii 50),
    proficiency-level: uint, ;; 1-5 scale
    verified: bool,
    endorsements: uint,
    added-at: uint
  }
)

(define-map work-history
  { worker: principal, gig-id: uint }
  {
    platform: (string-ascii 50),
    gig-type: (string-ascii 50),
    completion-date: uint,
    payment-amount: uint,
    client-rating: uint,
    gig-description: (string-ascii 200),
    skills-used: (list 10 (string-ascii 30))
  }
)

(define-map skill-endorsements
  { endorser: principal, worker: principal, skill-id: uint }
  {
    endorsed-at: uint,
    endorsement-score: uint
  }
)

(define-map platform-verifications
  { worker: principal, platform: (string-ascii 50) }
  {
    verification-status: bool,
    verified-at: uint,
    verification-hash: (string-ascii 64),
    total-platform-gigs: uint
  }
)

;; Data Variables
(define-data-var next-skill-id uint u1)
(define-data-var next-gig-id uint u1)
(define-data-var total-workers uint u0)
(define-data-var contract-owner principal tx-sender)

;; Private Functions
(define-private (is-valid-name (name (string-ascii 50)))
  (and (> (len name) u0) (<= (len name) MAX-NAME-LENGTH))
)

(define-private (is-valid-description (desc (string-ascii 500)))
  (<= (len desc) MAX-DESCRIPTION-LENGTH)
)

(define-private (is-valid-rating (rating uint))
  (and (>= rating MIN-RATING) (<= rating MAX-RATING))
)

(define-private (calculate-average-rating (current-avg uint) (current-count uint) (new-rating uint))
  (if (is-eq current-count u0)
    new-rating
    (/ (+ (* current-avg current-count) new-rating) (+ current-count u1))
  )
)

(define-private (get-worker-skill-count (worker principal))
  (fold check-skill-exists (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11 u12 u13 u14 u15 u16 u17 u18 u19 u20) 
    { worker: worker, count: u0 }
  )
)

(define-private (check-skill-exists (skill-id uint) (acc { worker: principal, count: uint }))
  (if (is-some (map-get? worker-skills { worker: (get worker acc), skill-id: skill-id }))
    { worker: (get worker acc), count: (+ (get count acc) u1) }
    acc
  )
)

(define-private (update-worker-stats (worker principal) (payment uint) (rating uint))
  (let (
    (current-profile (unwrap! (map-get? worker-profiles { worker: worker }) (err ERR-WORKER-NOT-FOUND)))
    (new-total-gigs (+ (get total-gigs current-profile) u1))
    (new-total-earnings (+ (get total-earnings current-profile) payment))
    (current-rating-count (get rating-count current-profile))
    (new-average-rating (calculate-average-rating (get average-rating current-profile) current-rating-count rating))
  )
    (map-set worker-profiles
      { worker: worker }
      (merge current-profile {
        total-gigs: new-total-gigs,
        total-earnings: new-total-earnings,
        average-rating: new-average-rating,
        rating-count: (+ current-rating-count u1),
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

;; Public Functions
(define-public (register-worker (name (string-ascii 50)) (description (string-ascii 500)) (portfolio-hash (string-ascii 64)))
  (let (
    (worker tx-sender)
  )
    (asserts! (is-valid-name name) ERR-INVALID-INPUT)
    (asserts! (is-valid-description description) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? worker-profiles { worker: worker })) ERR-ALREADY-EXISTS)
    (asserts! (>= (stx-get-balance tx-sender) REGISTRATION-FEE) ERR-INSUFFICIENT-BALANCE)
    
    (try! (stx-transfer? REGISTRATION-FEE tx-sender (var-get contract-owner)))
    
    (map-set worker-profiles
      { worker: worker }
      {
        name: name,
        description: description,
        created-at: stacks-block-height,
        updated-at: stacks-block-height,
        total-gigs: u0,
        total-earnings: u0,
        average-rating: u0,
        rating-count: u0,
        is-verified: false,
        portfolio-hash: portfolio-hash,
        profile-status: "active"
      }
    )
    
    (var-set total-workers (+ (var-get total-workers) u1))
    (ok worker)
  )
)

(define-public (update-worker-profile (name (string-ascii 50)) (description (string-ascii 500)) (portfolio-hash (string-ascii 64)))
  (let (
    (worker tx-sender)
    (current-profile (unwrap! (map-get? worker-profiles { worker: worker }) ERR-WORKER-NOT-FOUND))
  )
    (asserts! (is-valid-name name) ERR-INVALID-INPUT)
    (asserts! (is-valid-description description) ERR-INVALID-INPUT)
    
    (map-set worker-profiles
      { worker: worker }
      (merge current-profile {
        name: name,
        description: description,
        portfolio-hash: portfolio-hash,
        updated-at: stacks-block-height
      })
    )
    (ok true)
  )
)

(define-public (add-skill (skill-name (string-ascii 50)) (proficiency-level uint))
  (let (
    (worker tx-sender)
    (skill-id (var-get next-skill-id))
    (current-skill-count (get count (get-worker-skill-count worker)))
  )
    (asserts! (is-some (map-get? worker-profiles { worker: worker })) ERR-WORKER-NOT-FOUND)
    (asserts! (> (len skill-name) u0) ERR-INVALID-SKILL)
    (asserts! (and (>= proficiency-level u1) (<= proficiency-level u5)) ERR-INVALID-SKILL)
    (asserts! (< current-skill-count MAX-SKILLS) ERR-MAX-SKILLS-REACHED)
    
    (map-set worker-skills
      { worker: worker, skill-id: skill-id }
      {
        skill-name: skill-name,
        proficiency-level: proficiency-level,
        verified: false,
        endorsements: u0,
        added-at: stacks-block-height
      }
    )
    
    (var-set next-skill-id (+ skill-id u1))
    (ok skill-id)
  )
)

(define-public (endorse-skill (worker principal) (skill-id uint) (endorsement-score uint))
  (let (
    (endorser tx-sender)
    (skill-data (unwrap! (map-get? worker-skills { worker: worker, skill-id: skill-id }) ERR-INVALID-SKILL))
  )
    (asserts! (not (is-eq endorser worker)) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= endorsement-score u1) (<= endorsement-score u5)) ERR-INVALID-INPUT)
    (asserts! (is-some (map-get? worker-profiles { worker: endorser })) ERR-WORKER-NOT-FOUND)
    
    (map-set skill-endorsements
      { endorser: endorser, worker: worker, skill-id: skill-id }
      {
        endorsed-at: stacks-block-height,
        endorsement-score: endorsement-score
      }
    )
    
    (map-set worker-skills
      { worker: worker, skill-id: skill-id }
      (merge skill-data {
        endorsements: (+ (get endorsements skill-data) u1)
      })
    )
    
    (ok true)
  )
)

(define-public (add-work-history (platform (string-ascii 50)) (gig-type (string-ascii 50)) (payment-amount uint) (client-rating uint) (gig-description (string-ascii 200)) (skills-used (list 10 (string-ascii 30))))
  (let (
    (worker tx-sender)
    (gig-id (var-get next-gig-id))
  )
    (asserts! (is-some (map-get? worker-profiles { worker: worker })) ERR-WORKER-NOT-FOUND)
    (asserts! (> (len platform) u0) ERR-INVALID-INPUT)
    (asserts! (is-valid-rating client-rating) ERR-INVALID-RATING)
    
    (map-set work-history
      { worker: worker, gig-id: gig-id }
      {
        platform: platform,
        gig-type: gig-type,
        completion-date: stacks-block-height,
        payment-amount: payment-amount,
        client-rating: client-rating,
        gig-description: gig-description,
        skills-used: skills-used
      }
    )
    
    (try! (update-worker-stats worker payment-amount client-rating))
    (var-set next-gig-id (+ gig-id u1))
    (ok gig-id)
  )
)

(define-public (verify-platform (worker principal) (platform (string-ascii 50)) (verification-hash (string-ascii 64)) (total-platform-gigs uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? worker-profiles { worker: worker })) ERR-WORKER-NOT-FOUND)
    
    (map-set platform-verifications
      { worker: worker, platform: platform }
      {
        verification-status: true,
        verified-at: stacks-block-height,
        verification-hash: verification-hash,
        total-platform-gigs: total-platform-gigs
      }
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-worker-profile (worker principal))
  (map-get? worker-profiles { worker: worker })
)

(define-read-only (get-worker-skill (worker principal) (skill-id uint))
  (map-get? worker-skills { worker: worker, skill-id: skill-id })
)

(define-read-only (get-work-history-entry (worker principal) (gig-id uint))
  (map-get? work-history { worker: worker, gig-id: gig-id })
)

(define-read-only (get-platform-verification (worker principal) (platform (string-ascii 50)))
  (map-get? platform-verifications { worker: worker, platform: platform })
)

(define-read-only (get-skill-endorsement (endorser principal) (worker principal) (skill-id uint))
  (map-get? skill-endorsements { endorser: endorser, worker: worker, skill-id: skill-id })
)

(define-read-only (get-total-workers)
  (var-get total-workers)
)

(define-read-only (get-next-skill-id)
  (var-get next-skill-id)
)

(define-read-only (get-next-gig-id)
  (var-get next-gig-id)
)

(define-read-only (is-worker-registered (worker principal))
  (is-some (map-get? worker-profiles { worker: worker }))
)
