;; fair-gig-rewards
;; Token incentives for platforms treating workers fairly and workers maintaining high service quality

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INSUFFICIENT-BALANCE (err u401))
(define-constant ERR-INVALID-AMOUNT (err u402))
(define-constant ERR-REWARD-NOT-FOUND (err u403))
(define-constant ERR-ALREADY-CLAIMED (err u404))
(define-constant ERR-NOT-ELIGIBLE (err u405))
(define-constant ERR-POOL-DEPLETED (err u406))
(define-constant ERR-INVALID-PLATFORM (err u407))
(define-constant ERR-COOLDOWN-ACTIVE (err u408))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u409))
(define-constant ERR-INVALID-MILESTONE (err u410))
(define-constant ERR-STAKING-NOT-FOUND (err u411))
(define-constant ERR-LOCK-PERIOD-ACTIVE (err u412))

;; Token Economics
(define-constant TOKEN-NAME "GigChain Rewards Token")
(define-constant TOKEN-SYMBOL "GRT")
(define-constant TOKEN-DECIMALS u6)
(define-constant TOKEN-TOTAL-SUPPLY u1000000000000) ;; 1 million tokens with 6 decimals

;; Reward Parameters
(define-constant WORKER-QUALITY-REWARD u1000) ;; Base reward for quality work
(define-constant PLATFORM-FAIRNESS-REWARD u5000) ;; Reward for fair platforms
(define-constant MIN-RATING-THRESHOLD u4) ;; Minimum 4-star rating for rewards
(define-constant MIN-GIGS-FOR-REWARD u5) ;; Minimum completed gigs
(define-constant REWARD-COOLDOWN-BLOCKS u1008) ;; ~7 days cooldown
(define-constant STAKING-LOCK-PERIOD u4032) ;; ~28 days lock period
(define-constant QUALITY-BONUS-MULTIPLIER u2) ;; 2x bonus for consistent quality

;; SIP-010 Trait Implementation
(define-fungible-token gig-rewards-token TOKEN-TOTAL-SUPPLY)

;; Data Maps
(define-map worker-rewards
  { worker: principal }
  {
    total-earned: uint,
    last-claim: uint,
    quality-streak: uint,
    bonus-multiplier: uint,
    pending-rewards: uint,
    reputation-score: uint,
    total-gigs-completed: uint
  }
)

(define-map platform-rewards
  { platform: (string-ascii 50) }
  {
    total-earned: uint,
    fairness-score: uint,
    last-evaluation: uint,
    worker-satisfaction: uint,
    dispute-resolution-rate: uint,
    total-workers: uint,
    bonus-pool: uint
  }
)

(define-map reward-pools
  { pool-type: (string-ascii 20) }
  {
    total-allocated: uint,
    total-distributed: uint,
    current-balance: uint,
    last-replenished: uint,
    distribution-rate: uint
  }
)

(define-map staking-positions
  { staker: principal }
  {
    staked-amount: uint,
    stake-time: uint,
    lock-period: uint,
    earned-rewards: uint,
    last-claim: uint,
    auto-restake: bool
  }
)

(define-map quality-milestones
  { worker: principal, milestone-id: uint }
  {
    gigs-threshold: uint,
    rating-threshold: uint,
    reward-amount: uint,
    achieved: bool,
    achieved-at: (optional uint)
  }
)

(define-map platform-partnerships
  { platform: (string-ascii 50) }
  {
    partner-status: bool,
    reward-multiplier: uint,
    min-worker-count: uint,
    performance-requirements: (list 5 uint),
    last-review: uint
  }
)

(define-map governance-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 20),
    created-at: uint,
    voting-deadline: uint
  }
)

;; Data Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-supply uint TOKEN-TOTAL-SUPPLY)
(define-data-var next-proposal-id uint u1)
(define-data-var reward-distribution-active bool true)
(define-data-var platform-evaluation-frequency uint u2016) ;; ~14 days

;; Private Functions
(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b)
)

(define-private (calculate-worker-quality-score (worker principal))
  (let (
    (worker-data (default-to 
      { total-earned: u0, last-claim: u0, quality-streak: u0, bonus-multiplier: u1, pending-rewards: u0, reputation-score: u0, total-gigs-completed: u0 }
      (map-get? worker-rewards { worker: worker })
    ))
    (base-score (get reputation-score worker-data))
    (streak-bonus (* (get quality-streak worker-data) u10))
    (gig-experience-bonus (min (* (get total-gigs-completed worker-data) u2) u100))
  )
    (+ base-score streak-bonus gig-experience-bonus)
  )
)

(define-private (calculate-platform-fairness-score (platform (string-ascii 50)))
  (let (
    (platform-data (default-to 
      { total-earned: u0, fairness-score: u0, last-evaluation: u0, worker-satisfaction: u0, dispute-resolution-rate: u0, total-workers: u0, bonus-pool: u0 }
      (map-get? platform-rewards { platform: platform })
    ))
    (satisfaction-score (get worker-satisfaction platform-data))
    (dispute-score (get dispute-resolution-rate platform-data))
    (worker-count-bonus (min (* (get total-workers platform-data) u5) u200))
  )
    (/ (+ satisfaction-score dispute-score worker-count-bonus) u3)
  )
)

(define-private (is-eligible-for-reward (worker principal))
  (let (
    (worker-data (map-get? worker-rewards { worker: worker }))
  )
    (match worker-data
      data (let (
        (cooldown-passed (> (- stacks-block-height (get last-claim data)) REWARD-COOLDOWN-BLOCKS))
        (min-gigs-met (>= (get total-gigs-completed data) MIN-GIGS-FOR-REWARD))
        (quality-threshold-met (>= (get reputation-score data) (* MIN-RATING-THRESHOLD u20)))
      )
        (and cooldown-passed min-gigs-met quality-threshold-met)
      )
      false
    )
  )
)

(define-private (update-quality-streak (worker principal) (gig-rating uint))
  (let (
    (worker-data (default-to 
      { total-earned: u0, last-claim: u0, quality-streak: u0, bonus-multiplier: u1, pending-rewards: u0, reputation-score: u0, total-gigs-completed: u0 }
      (map-get? worker-rewards { worker: worker })
    ))
    (current-streak (get quality-streak worker-data))
    (new-streak (if (>= gig-rating MIN-RATING-THRESHOLD) (+ current-streak u1) u0))
    (new-multiplier (if (> new-streak u10) QUALITY-BONUS-MULTIPLIER u1))
  )
    (map-set worker-rewards
      { worker: worker }
      (merge worker-data {
        quality-streak: new-streak,
        bonus-multiplier: new-multiplier,
        total-gigs-completed: (+ (get total-gigs-completed worker-data) u1)
      })
    )
  )
)

(define-private (distribute-pool-rewards (pool-type (string-ascii 20)) (amount uint))
  (let (
    (pool-data (default-to 
      { total-allocated: u0, total-distributed: u0, current-balance: u0, last-replenished: u0, distribution-rate: u100 }
      (map-get? reward-pools { pool-type: pool-type })
    ))
  )
    (asserts! (>= (get current-balance pool-data) amount) (err ERR-POOL-DEPLETED))
    (map-set reward-pools
      { pool-type: pool-type }
      (merge pool-data {
        total-distributed: (+ (get total-distributed pool-data) amount),
        current-balance: (- (get current-balance pool-data) amount)
      })
    )
    (ok true)
  )
)

(define-private (calculate-staking-rewards (staker principal))
  (let (
    (staking-data (unwrap! (map-get? staking-positions { staker: staker }) (err ERR-STAKING-NOT-FOUND)))
    (stake-duration (- stacks-block-height (get stake-time staking-data)))
    (annual-rate u10) ;; 10% annual rate
    (daily-rate (/ annual-rate u365))
    (days-staked (/ stake-duration u144)) ;; blocks per day
    (reward-amount (/ (* (get staked-amount staking-data) daily-rate days-staked) u100))
  )
    (ok reward-amount)
  )
)

;; Public Functions - SIP-010 Interface
(define-public (transfer (amount uint) (from principal) (to principal) (memo (optional (buff 34))))
  (begin
    (asserts! (or (is-eq tx-sender from) (is-eq contract-caller from)) (err ERR-NOT-AUTHORIZED))
    (ft-transfer? gig-rewards-token amount from to)
  )
)

(define-public (get-name)
  (ok TOKEN-NAME)
)

(define-public (get-symbol)
  (ok TOKEN-SYMBOL)
)

(define-public (get-decimals)
  (ok TOKEN-DECIMALS)
)

(define-public (get-balance (who principal))
  (ok (ft-get-balance gig-rewards-token who))
)

(define-public (get-total-supply)
  (ok (ft-get-supply gig-rewards-token))
)

(define-public (get-token-uri)
  (ok none)
)

;; Public Functions - Reward System
(define-public (mint-tokens (recipient principal) (amount uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    (ft-mint? gig-rewards-token amount recipient)
  )
)

(define-public (reward-quality-work (worker principal) (gig-rating uint) (gig-value uint))
  (let (
    (base-reward WORKER-QUALITY-REWARD)
    (worker-data (default-to 
      { total-earned: u0, last-claim: u0, quality-streak: u0, bonus-multiplier: u1, pending-rewards: u0, reputation-score: u0, total-gigs-completed: u0 }
      (map-get? worker-rewards { worker: worker })
    ))
    (quality-multiplier (if (>= gig-rating u5) u2 u1)) ;; 2x for 5-star rating
    (value-bonus (min (/ gig-value u10) u500)) ;; Bonus based on gig value
    (streak-multiplier (get bonus-multiplier worker-data))
    (total-reward (* (* (+ base-reward value-bonus) quality-multiplier) streak-multiplier))
  )
    (asserts! (>= gig-rating MIN-RATING-THRESHOLD) (err ERR-NOT-ELIGIBLE))
    (asserts! (var-get reward-distribution-active) (err ERR-NOT-AUTHORIZED))
    
    (try! (distribute-pool-rewards "worker-quality" total-reward))
    (try! (ft-mint? gig-rewards-token total-reward worker))
    
    ;; Update worker data
    (update-quality-streak worker gig-rating)
    (map-set worker-rewards
      { worker: worker }
      (merge worker-data {
        total-earned: (+ (get total-earned worker-data) total-reward),
        pending-rewards: (+ (get pending-rewards worker-data) total-reward),
        reputation-score: (/ (+ (* (get reputation-score worker-data) (get total-gigs-completed worker-data)) (* gig-rating u20)) (+ (get total-gigs-completed worker-data) u1))
      })
    )
    
    (ok total-reward)
  )
)

(define-public (reward-fair-platform (platform (string-ascii 50)) (performance-metrics (list 5 uint)))
  (let (
    (fairness-score (calculate-platform-fairness-score platform))
    (base-reward PLATFORM-FAIRNESS-REWARD)
    (performance-bonus (fold + performance-metrics u0))
    (total-reward (+ base-reward performance-bonus))
    (platform-data (default-to 
      { total-earned: u0, fairness-score: u0, last-evaluation: u0, worker-satisfaction: u0, dispute-resolution-rate: u0, total-workers: u0, bonus-pool: u0 }
      (map-get? platform-rewards { platform: platform })
    ))
  )
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    (asserts! (>= fairness-score u70) (err ERR-NOT-ELIGIBLE)) ;; Minimum 70% fairness score
    
    (try! (distribute-pool-rewards "platform-fairness" total-reward))
    
    ;; Mint rewards to platform's bonus pool
    (map-set platform-rewards
      { platform: platform }
      (merge platform-data {
        total-earned: (+ (get total-earned platform-data) total-reward),
        bonus-pool: (+ (get bonus-pool platform-data) total-reward),
        last-evaluation: stacks-block-height,
        fairness-score: fairness-score
      })
    )
    
    (ok total-reward)
  )
)

(define-public (claim-worker-rewards)
  (let (
    (worker tx-sender)
    (worker-data (unwrap! (map-get? worker-rewards { worker: worker }) (err ERR-REWARD-NOT-FOUND)))
    (pending-amount (get pending-rewards worker-data))
  )
    (asserts! (> pending-amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (is-eligible-for-reward worker) (err ERR-NOT-ELIGIBLE))
    
    (map-set worker-rewards
      { worker: worker }
      (merge worker-data {
        pending-rewards: u0,
        last-claim: stacks-block-height
      })
    )
    
    (ok pending-amount)
  )
)

(define-public (stake-tokens (amount uint) (lock-period uint))
  (let (
    (staker tx-sender)
    (min-lock-period STAKING-LOCK-PERIOD)
  )
    (asserts! (>= amount u1000) (err ERR-INVALID-AMOUNT)) ;; Minimum stake
    (asserts! (>= lock-period min-lock-period) (err ERR-INVALID-AMOUNT))
    (asserts! (>= (ft-get-balance gig-rewards-token staker) amount) (err ERR-INSUFFICIENT-BALANCE))
    
    (try! (ft-transfer? gig-rewards-token amount staker (as-contract tx-sender)))
    
    (map-set staking-positions
      { staker: staker }
      {
        staked-amount: amount,
        stake-time: stacks-block-height,
        lock-period: lock-period,
        earned-rewards: u0,
        last-claim: stacks-block-height,
        auto-restake: false
      }
    )
    
    (ok true)
  )
)

(define-public (unstake-tokens)
  (let (
    (staker tx-sender)
    (staking-data (unwrap! (map-get? staking-positions { staker: staker }) (err ERR-STAKING-NOT-FOUND)))
    (lock-end (+ (get stake-time staking-data) (get lock-period staking-data)))
  )
    (asserts! (>= stacks-block-height lock-end) (err ERR-LOCK-PERIOD-ACTIVE))
    
    (let (
      (staked-amount (get staked-amount staking-data))
      (earned-rewards (unwrap! (calculate-staking-rewards staker) (err ERR-STAKING-NOT-FOUND)))
      (total-return (+ staked-amount earned-rewards))
    )
      (try! (as-contract (ft-transfer? gig-rewards-token total-return tx-sender staker)))
      (map-delete staking-positions { staker: staker })
      (ok total-return)
    )
  )
)

(define-public (create-quality-milestone (worker principal) (gigs-threshold uint) (rating-threshold uint) (reward-amount uint))
  (let (
    (milestone-id (get total-gigs-completed (default-to 
      { total-earned: u0, last-claim: u0, quality-streak: u0, bonus-multiplier: u1, pending-rewards: u0, reputation-score: u0, total-gigs-completed: u0 }
      (map-get? worker-rewards { worker: worker })
    )))
  )
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    
    (map-set quality-milestones
      { worker: worker, milestone-id: milestone-id }
      {
        gigs-threshold: gigs-threshold,
        rating-threshold: rating-threshold,
        reward-amount: reward-amount,
        achieved: false,
        achieved-at: none
      }
    )
    (ok milestone-id)
  )
)

(define-public (replenish-reward-pool (pool-type (string-ascii 20)) (amount uint))
  (let (
    (pool-data (default-to 
      { total-allocated: u0, total-distributed: u0, current-balance: u0, last-replenished: u0, distribution-rate: u100 }
      (map-get? reward-pools { pool-type: pool-type })
    ))
  )
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    
    (map-set reward-pools
      { pool-type: pool-type }
      (merge pool-data {
        total-allocated: (+ (get total-allocated pool-data) amount),
        current-balance: (+ (get current-balance pool-data) amount),
        last-replenished: stacks-block-height
      })
    )
    
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-worker-rewards (worker principal))
  (map-get? worker-rewards { worker: worker })
)

(define-read-only (get-platform-rewards (platform (string-ascii 50)))
  (map-get? platform-rewards { platform: platform })
)

(define-read-only (get-reward-pool (pool-type (string-ascii 20)))
  (map-get? reward-pools { pool-type: pool-type })
)

(define-read-only (get-staking-position (staker principal))
  (map-get? staking-positions { staker: staker })
)

(define-read-only (get-quality-milestone (worker principal) (milestone-id uint))
  (map-get? quality-milestones { worker: worker, milestone-id: milestone-id })
)

(define-read-only (calculate-potential-reward (worker principal) (gig-rating uint) (gig-value uint))
  (let (
    (base-reward WORKER-QUALITY-REWARD)
    (worker-data (default-to 
      { total-earned: u0, last-claim: u0, quality-streak: u0, bonus-multiplier: u1, pending-rewards: u0, reputation-score: u0, total-gigs-completed: u0 }
      (map-get? worker-rewards { worker: worker })
    ))
    (quality-multiplier (if (>= gig-rating u5) u2 u1))
    (value-bonus (min (/ gig-value u10) u500))
    (streak-multiplier (get bonus-multiplier worker-data))
  )
    (* (* (+ base-reward value-bonus) quality-multiplier) streak-multiplier)
  )
)

(define-read-only (get-platform-partnership (platform (string-ascii 50)))
  (map-get? platform-partnerships { platform: platform })
)

(define-read-only (get-governance-proposal (proposal-id uint))
  (map-get? governance-proposals { proposal-id: proposal-id })
)

(define-read-only (get-contract-stats)
  {
    total-supply: (ft-get-supply gig-rewards-token),
    reward-distribution-active: (var-get reward-distribution-active),
    next-proposal-id: (var-get next-proposal-id),
    contract-owner: (var-get contract-owner)
  }
)
