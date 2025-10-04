;; payment-protection-system
;; Escrow payments ensuring workers receive fair compensation for completed gig work

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-ESCROW-NOT-FOUND (err u201))
(define-constant ERR-INVALID-AMOUNT (err u202))
(define-constant ERR-INVALID-STATE (err u203))
(define-constant ERR-INSUFFICIENT-BALANCE (err u204))
(define-constant ERR-ALREADY-EXISTS (err u205))
(define-constant ERR-DEADLINE-PASSED (err u206))
(define-constant ERR-MILESTONE-NOT-FOUND (err u207))
(define-constant ERR-DISPUTE-EXISTS (err u208))
(define-constant ERR-INVALID-MILESTONE (err u209))
(define-constant ERR-PAYMENT-ALREADY-RELEASED (err u210))
(define-constant ERR-INVALID-DISPUTE (err u211))
(define-constant ERR-ARBITRATOR-NOT-SET (err u212))

(define-constant ESCROW-FEE-PERCENTAGE u3) ;; 3% fee
(define-constant MIN-ESCROW-AMOUNT u1000) ;; 1000 micro-STX minimum
(define-constant MAX-MILESTONES u10)
(define-constant DISPUTE-WINDOW-BLOCKS u1008) ;; ~7 days
(define-constant AUTO-RELEASE-BLOCKS u2016) ;; ~14 days

;; Escrow states
(define-constant STATE-CREATED "created")
(define-constant STATE-FUNDED "funded")
(define-constant STATE-IN-PROGRESS "in-progress")
(define-constant STATE-COMPLETED "completed")
(define-constant STATE-DISPUTED "disputed")
(define-constant STATE-RESOLVED "resolved")
(define-constant STATE-CANCELLED "cancelled")

;; Data Maps
(define-map escrows
  { escrow-id: uint }
  {
    client: principal,
    worker: principal,
    total-amount: uint,
    fee-amount: uint,
    remaining-amount: uint,
    milestone-count: uint,
    created-at: uint,
    deadline: uint,
    state: (string-ascii 20),
    gig-description: (string-ascii 500),
    completion-criteria: (string-ascii 500)
  }
)

(define-map milestones
  { escrow-id: uint, milestone-id: uint }
  {
    amount: uint,
    description: (string-ascii 200),
    due-date: uint,
    completed-at: (optional uint),
    approved-by-client: bool,
    released: bool,
    completion-proof: (string-ascii 100)
  }
)

(define-map disputes
  { escrow-id: uint }
  {
    initiated-by: principal,
    initiated-at: uint,
    reason: (string-ascii 500),
    client-evidence: (string-ascii 500),
    worker-evidence: (string-ascii 500),
    arbitrator-decision: (optional (string-ascii 20)),
    resolved-at: (optional uint),
    resolution-amount: uint
  }
)

(define-map arbitrators
  { arbitrator: principal }
  {
    active: bool,
    cases-resolved: uint,
    rating: uint,
    fee-percentage: uint
  }
)

(define-map escrow-reviews
  { escrow-id: uint }
  {
    client-rating: (optional uint),
    worker-rating: (optional uint),
    client-review: (string-ascii 500),
    worker-review: (string-ascii 500),
    submitted-at: uint
  }
)

;; Data Variables
(define-data-var next-escrow-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var total-escrows uint u0)
(define-data-var total-volume uint u0)
(define-data-var platform-fee-pool uint u0)

;; Private Functions
(define-private (calculate-fee (amount uint))
  (/ (* amount ESCROW-FEE-PERCENTAGE) u100)
)

(define-private (is-valid-state-transition (current-state (string-ascii 20)) (new-state (string-ascii 20)))
  (or
    (and (is-eq current-state STATE-CREATED) (is-eq new-state STATE-FUNDED))
    (and (is-eq current-state STATE-FUNDED) (is-eq new-state STATE-IN-PROGRESS))
    (and (is-eq current-state STATE-IN-PROGRESS) (is-eq new-state STATE-COMPLETED))
    (and (is-eq current-state STATE-IN-PROGRESS) (is-eq new-state STATE-DISPUTED))
    (and (is-eq current-state STATE-DISPUTED) (is-eq new-state STATE-RESOLVED))
    (and (is-eq current-state STATE-CREATED) (is-eq new-state STATE-CANCELLED))
    (and (is-eq current-state STATE-FUNDED) (is-eq new-state STATE-CANCELLED))
  )
)

(define-private (check-milestone-completion (escrow-id uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) { escrow-id: escrow-id, count: u0, completed: u0 }))
    (milestone-count (get milestone-count escrow-data))
  )
    (fold check-individual-milestone (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10) 
      { escrow-id: escrow-id, count: milestone-count, completed: u0 }
    )
  )
)

(define-private (check-individual-milestone (milestone-id uint) (acc { escrow-id: uint, count: uint, completed: uint }))
  (if (> milestone-id (get count acc))
    acc
    (let (
      (milestone-data (map-get? milestones { escrow-id: (get escrow-id acc), milestone-id: milestone-id }))
    )
      (if (and (is-some milestone-data) (get released (unwrap-panic milestone-data)))
        (merge acc { completed: (+ (get completed acc) u1) })
        acc
      )
    )
  )
)

(define-private (calculate-auto-release-eligibility (escrow-id uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) false))
    (blocks-passed (- stacks-block-height (get created-at escrow-data)))
  )
    (> blocks-passed AUTO-RELEASE-BLOCKS)
  )
)

(define-private (update-escrow-state (escrow-id uint) (new-state (string-ascii 20)))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
  )
    (asserts! (is-valid-state-transition (get state escrow-data) new-state) (err ERR-INVALID-STATE))
    (map-set escrows
      { escrow-id: escrow-id }
      (merge escrow-data { state: new-state })
    )
    (ok true)
  )
)

;; Public Functions
(define-public (create-escrow (worker principal) (total-amount uint) (milestone-count uint) (deadline uint) (gig-description (string-ascii 500)) (completion-criteria (string-ascii 500)))
  (let (
    (escrow-id (var-get next-escrow-id))
    (client tx-sender)
    (fee-amount (calculate-fee total-amount))
    (net-amount (- total-amount fee-amount))
  )
    (asserts! (>= total-amount MIN-ESCROW-AMOUNT) (err ERR-INVALID-AMOUNT))
    (asserts! (and (> milestone-count u0) (<= milestone-count MAX-MILESTONES)) (err ERR-INVALID-MILESTONE))
    (asserts! (> deadline stacks-block-height) (err ERR-DEADLINE-PASSED))
    (asserts! (not (is-eq client worker)) (err ERR-NOT-AUTHORIZED))
    
    (map-set escrows
      { escrow-id: escrow-id }
      {
        client: client,
        worker: worker,
        total-amount: total-amount,
        fee-amount: fee-amount,
        remaining-amount: net-amount,
        milestone-count: milestone-count,
        created-at: stacks-block-height,
        deadline: deadline,
        state: STATE-CREATED,
        gig-description: gig-description,
        completion-criteria: completion-criteria
      }
    )
    
    (var-set next-escrow-id (+ escrow-id u1))
    (var-set total-escrows (+ (var-get total-escrows) u1))
    (ok escrow-id)
  )
)

(define-public (fund-escrow (escrow-id uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (get client escrow-data)) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-eq (get state escrow-data) STATE-CREATED) (err ERR-INVALID-STATE))
    (asserts! (>= (stx-get-balance tx-sender) (get total-amount escrow-data)) (err ERR-INSUFFICIENT-BALANCE))
    
    (try! (stx-transfer? (get total-amount escrow-data) tx-sender (as-contract tx-sender)))
    (try! (update-escrow-state escrow-id STATE-FUNDED))
    
    (var-set total-volume (+ (var-get total-volume) (get total-amount escrow-data)))
    (var-set platform-fee-pool (+ (var-get platform-fee-pool) (get fee-amount escrow-data)))
    (ok true)
  )
)

(define-public (create-milestone (escrow-id uint) (milestone-id uint) (amount uint) (description (string-ascii 200)) (due-date uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (get client escrow-data)) (err ERR-NOT-AUTHORIZED))
    (asserts! (and (> milestone-id u0) (<= milestone-id (get milestone-count escrow-data))) (err ERR-INVALID-MILESTONE))
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (> due-date stacks-block-height) (err ERR-DEADLINE-PASSED))
    (asserts! (is-none (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id })) (err ERR-ALREADY-EXISTS))
    
    (map-set milestones
      { escrow-id: escrow-id, milestone-id: milestone-id }
      {
        amount: amount,
        description: description,
        due-date: due-date,
        completed-at: none,
        approved-by-client: false,
        released: false,
        completion-proof: ""
      }
    )
    (ok true)
  )
)

(define-public (submit-milestone (escrow-id uint) (milestone-id uint) (completion-proof (string-ascii 100)))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (milestone-data (unwrap! (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id }) (err ERR-MILESTONE-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (get worker escrow-data)) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-eq (get state escrow-data) STATE-FUNDED) (err ERR-INVALID-STATE))
    (asserts! (is-none (get completed-at milestone-data)) (err ERR-PAYMENT-ALREADY-RELEASED))
    
    (map-set milestones
      { escrow-id: escrow-id, milestone-id: milestone-id }
      (merge milestone-data {
        completed-at: (some stacks-block-height),
        completion-proof: completion-proof
      })
    )
    
    (try! (update-escrow-state escrow-id STATE-IN-PROGRESS))
    (ok true)
  )
)

(define-public (approve-milestone (escrow-id uint) (milestone-id uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (milestone-data (unwrap! (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id }) (err ERR-MILESTONE-NOT-FOUND)))
  )
    (asserts! (is-eq tx-sender (get client escrow-data)) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-some (get completed-at milestone-data)) (err ERR-INVALID-STATE))
    (asserts! (not (get approved-by-client milestone-data)) (err ERR-PAYMENT-ALREADY-RELEASED))
    
    (map-set milestones
      { escrow-id: escrow-id, milestone-id: milestone-id }
      (merge milestone-data { approved-by-client: true })
    )
    (ok true)
  )
)

(define-public (release-milestone-payment (escrow-id uint) (milestone-id uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (milestone-data (unwrap! (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id }) (err ERR-MILESTONE-NOT-FOUND)))
  )
    (asserts! (or (is-eq tx-sender (get client escrow-data)) (is-eq tx-sender (get worker escrow-data))) (err ERR-NOT-AUTHORIZED))
    (asserts! (get approved-by-client milestone-data) (err ERR-INVALID-STATE))
    (asserts! (not (get released milestone-data)) (err ERR-PAYMENT-ALREADY-RELEASED))
    
    (try! (as-contract (stx-transfer? (get amount milestone-data) tx-sender (get worker escrow-data))))
    
    (map-set milestones
      { escrow-id: escrow-id, milestone-id: milestone-id }
      (merge milestone-data { released: true })
    )
    
    (map-set escrows
      { escrow-id: escrow-id }
      (merge escrow-data {
        remaining-amount: (- (get remaining-amount escrow-data) (get amount milestone-data))
      })
    )
    
    ;; Check if all milestones completed
    (let (
      (completion-check (check-milestone-completion escrow-id))
    )
      (if (is-eq (get completed completion-check) (get milestone-count escrow-data))
        (try! (update-escrow-state escrow-id STATE-COMPLETED))
        (ok true)
      )
    )
  )
)

(define-public (initiate-dispute (escrow-id uint) (reason (string-ascii 500)))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (initiator tx-sender)
  )
    (asserts! (or (is-eq initiator (get client escrow-data)) (is-eq initiator (get worker escrow-data))) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-eq (get state escrow-data) STATE-IN-PROGRESS) (err ERR-INVALID-STATE))
    (asserts! (is-none (map-get? disputes { escrow-id: escrow-id })) (err ERR-DISPUTE-EXISTS))
    
    (map-set disputes
      { escrow-id: escrow-id }
      {
        initiated-by: initiator,
        initiated-at: stacks-block-height,
        reason: reason,
        client-evidence: "",
        worker-evidence: "",
        arbitrator-decision: none,
        resolved-at: none,
        resolution-amount: u0
      }
    )
    
    (try! (update-escrow-state escrow-id STATE-DISPUTED))
    (ok true)
  )
)

(define-public (submit-evidence (escrow-id uint) (evidence (string-ascii 500)))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (dispute-data (unwrap! (map-get? disputes { escrow-id: escrow-id }) (err ERR-INVALID-DISPUTE)))
    (submitter tx-sender)
  )
    (asserts! (or (is-eq submitter (get client escrow-data)) (is-eq submitter (get worker escrow-data))) (err ERR-NOT-AUTHORIZED))
    (asserts! (is-eq (get state escrow-data) STATE-DISPUTED) (err ERR-INVALID-STATE))
    
    (if (is-eq submitter (get client escrow-data))
      (map-set disputes
        { escrow-id: escrow-id }
        (merge dispute-data { client-evidence: evidence })
      )
      (map-set disputes
        { escrow-id: escrow-id }
        (merge dispute-data { worker-evidence: evidence })
      )
    )
    (ok true)
  )
)

(define-public (resolve-dispute (escrow-id uint) (decision (string-ascii 20)) (resolution-amount uint))
  (let (
    (escrow-data (unwrap! (map-get? escrows { escrow-id: escrow-id }) (err ERR-ESCROW-NOT-FOUND)))
    (dispute-data (unwrap! (map-get? disputes { escrow-id: escrow-id }) (err ERR-INVALID-DISPUTE)))
    (arbitrator tx-sender)
  )
    (asserts! (is-some (map-get? arbitrators { arbitrator: arbitrator })) (err ERR-ARBITRATOR-NOT-SET))
    (asserts! (is-eq (get state escrow-data) STATE-DISPUTED) (err ERR-INVALID-STATE))
    (asserts! (<= resolution-amount (get remaining-amount escrow-data)) (err ERR-INVALID-AMOUNT))
    
    (if (> resolution-amount u0)
      (try! (as-contract (stx-transfer? resolution-amount tx-sender (get worker escrow-data))))
      (ok true)
    )
    
    (let (
      (remaining-to-client (- (get remaining-amount escrow-data) resolution-amount))
    )
      (if (> remaining-to-client u0)
        (try! (as-contract (stx-transfer? remaining-to-client tx-sender (get client escrow-data))))
        (ok true)
      )
    )
    
    (map-set disputes
      { escrow-id: escrow-id }
      (merge dispute-data {
        arbitrator-decision: (some decision),
        resolved-at: (some stacks-block-height),
        resolution-amount: resolution-amount
      })
    )
    
    (try! (update-escrow-state escrow-id STATE-RESOLVED))
    (ok true)
  )
)

(define-public (register-arbitrator (fee-percentage uint))
  (begin
    (asserts! (<= fee-percentage u10) (err ERR-INVALID-AMOUNT)) ;; Max 10% fee
    (map-set arbitrators
      { arbitrator: tx-sender }
      {
        active: true,
        cases-resolved: u0,
        rating: u0,
        fee-percentage: fee-percentage
      }
    )
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-escrow (escrow-id uint))
  (map-get? escrows { escrow-id: escrow-id })
)

(define-read-only (get-milestone (escrow-id uint) (milestone-id uint))
  (map-get? milestones { escrow-id: escrow-id, milestone-id: milestone-id })
)

(define-read-only (get-dispute (escrow-id uint))
  (map-get? disputes { escrow-id: escrow-id })
)

(define-read-only (get-arbitrator (arbitrator principal))
  (map-get? arbitrators { arbitrator: arbitrator })
)

(define-read-only (get-platform-stats)
  {
    total-escrows: (var-get total-escrows),
    total-volume: (var-get total-volume),
    fee-pool: (var-get platform-fee-pool),
    next-escrow-id: (var-get next-escrow-id)
  }
)

(define-read-only (calculate-escrow-fee (amount uint))
  (calculate-fee amount)
)
