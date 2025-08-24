;; Player Management Smart Contract
;; Handles player registration, profiles, and identity management

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-PLAYER-NOT-FOUND (err u201))
(define-constant ERR-PLAYER-ALREADY-EXISTS (err u202))
(define-constant ERR-INVALID-PARAMETERS (err u203))
(define-constant ERR-PROFILE-LOCKED (err u204))
(define-constant ERR-IDENTITY-NOT-VERIFIED (err u205))
(define-constant ERR-INVALID-VERIFICATION-CODE (err u206))
(define-constant ERR-VERIFICATION-EXPIRED (err u207))
(define-constant ERR-PLAYER-SUSPENDED (err u208))

;; Player status constants
(define-constant STATUS-PENDING u1)
(define-constant STATUS-ACTIVE u2)
(define-constant STATUS-SUSPENDED u3)
(define-constant STATUS-BANNED u4)

;; Identity verification levels
(define-constant VERIFICATION-NONE u0)
(define-constant VERIFICATION-EMAIL u1)
(define-constant VERIFICATION-PHONE u2)
(define-constant VERIFICATION-KYC u3)

;; Data structures
(define-map players
  { player: principal }
  {
    username: (string-ascii 50),
    display-name: (string-utf8 100),
    email-hash: (buff 32),
    phone-hash: (buff 32),
    bio: (string-utf8 500),
    avatar-url: (string-ascii 200),
    status: uint,
    verification-level: uint,
    reputation-score: uint,
    registration-date: uint,
    last-active: uint,
    profile-locked: bool,
    kyc-verified: bool
  }
)

(define-map player-usernames
  { username: (string-ascii 50) }
  { player: principal }
)

(define-map verification-codes
  { player: principal, verification-type: uint }
  {
    code-hash: (buff 32),
    created-at: uint,
    expires-at: uint,
    attempts: uint,
    verified: bool
  }
)

(define-map player-permissions
  { player: principal }
  {
    can-create-elections: bool,
    can-vote: bool,
    can-moderate: bool,
    is-admin: bool
  }
)

(define-map player-stats
  { player: principal }
  {
    elections-created: uint,
    elections-voted: uint,
    total-votes-cast: uint,
    referrals-made: uint,
    reports-filed: uint,
    warnings-received: uint
  }
)

(define-map admin-actions
  { action-id: uint }
  {
    admin: principal,
    target-player: principal,
    action-type: (string-ascii 50),
    reason: (string-utf8 300),
    timestamp: uint,
    active: bool
  }
)

;; Global variables
(define-data-var next-action-id uint u1)
(define-data-var total-players uint u0)
(define-data-var verification-code-expiry uint u144) ;; blocks (~24 hours)
(define-data-var max-verification-attempts uint u5)

;; Public functions

;; Register a new player
(define-public (register-player 
  (username (string-ascii 50))
  (display-name (string-utf8 100))
  (email-hash (buff 32))
  (phone-hash (buff 32))
  (bio (string-utf8 500))
  (avatar-url (string-ascii 200))
)
  (let 
    (
      (current-block stacks-block-height)
      (player-exists (is-some (map-get? players { player: tx-sender })))
      (username-taken (is-some (map-get? player-usernames { username: username })))
    )
    ;; Validate registration
    (asserts! (not player-exists) ERR-PLAYER-ALREADY-EXISTS)
    (asserts! (not username-taken) ERR-PLAYER-ALREADY-EXISTS)
    (asserts! (> (len username) u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= (len username) u50) ERR-INVALID-PARAMETERS)
    (asserts! (> (len display-name) u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= (len display-name) u100) ERR-INVALID-PARAMETERS)
    
    ;; Create player profile
    (map-set players
      { player: tx-sender }
      {
        username: username,
        display-name: display-name,
        email-hash: email-hash,
        phone-hash: phone-hash,
        bio: bio,
        avatar-url: avatar-url,
        status: STATUS-PENDING,
        verification-level: VERIFICATION-NONE,
        reputation-score: u100,
        registration-date: current-block,
        last-active: current-block,
        profile-locked: false,
        kyc-verified: false
      }
    )
    
    ;; Reserve username
    (map-set player-usernames
      { username: username }
      { player: tx-sender }
    )
    
    ;; Set default permissions
    (map-set player-permissions
      { player: tx-sender }
      {
        can-create-elections: true,
        can-vote: true,
        can-moderate: false,
        is-admin: false
      }
    )
    
    ;; Initialize stats
    (map-set player-stats
      { player: tx-sender }
      {
        elections-created: u0,
        elections-voted: u0,
        total-votes-cast: u0,
        referrals-made: u0,
        reports-filed: u0,
        warnings-received: u0
      }
    )
    
    ;; Update global counter
    (var-set total-players (+ (var-get total-players) u1))
    
    (ok true)
  )
)

;; Update player profile
(define-public (update-profile
  (display-name (string-utf8 100))
  (bio (string-utf8 500))
  (avatar-url (string-ascii 200))
)
  (let 
    (
      (player-data (unwrap! (map-get? players { player: tx-sender }) ERR-PLAYER-NOT-FOUND))
      (current-block stacks-block-height)
    )
    ;; Check if profile is locked
    (asserts! (not (get profile-locked player-data)) ERR-PROFILE-LOCKED)
    
    ;; Validate parameters
    (asserts! (> (len display-name) u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= (len display-name) u100) ERR-INVALID-PARAMETERS)
    (asserts! (<= (len bio) u500) ERR-INVALID-PARAMETERS)
    (asserts! (<= (len avatar-url) u200) ERR-INVALID-PARAMETERS)
    
    ;; Update profile
    (map-set players
      { player: tx-sender }
      (merge player-data {
        display-name: display-name,
        bio: bio,
        avatar-url: avatar-url,
        last-active: current-block
      })
    )
    
    (ok true)
  )
)

;; Request identity verification
(define-public (request-verification 
  (verification-type uint)
  (code-hash (buff 32))
)
  (let 
    (
      (player-data (unwrap! (map-get? players { player: tx-sender }) ERR-PLAYER-NOT-FOUND))
      (current-block stacks-block-height)
      (expires-at (+ current-block (var-get verification-code-expiry)))
    )
    ;; Validate verification type
    (asserts! (or (is-eq verification-type VERIFICATION-EMAIL)
                  (is-eq verification-type VERIFICATION-PHONE)
                  (is-eq verification-type VERIFICATION-KYC)) ERR-INVALID-PARAMETERS)
    
    ;; Store verification code
    (map-set verification-codes
      { player: tx-sender, verification-type: verification-type }
      {
        code-hash: code-hash,
        created-at: current-block,
        expires-at: expires-at,
        attempts: u0,
        verified: false
      }
    )
    
    (ok true)
  )
)

;; Verify identity with code
(define-public (verify-identity
  (verification-type uint)
  (code-hash (buff 32))
)
  (let 
    (
      (player-data (unwrap! (map-get? players { player: tx-sender }) ERR-PLAYER-NOT-FOUND))
      (verification-data (unwrap! (map-get? verification-codes 
        { player: tx-sender, verification-type: verification-type }) ERR-INVALID-VERIFICATION-CODE))
      (current-block stacks-block-height)
    )
    ;; Check if verification is not expired
    (asserts! (< current-block (get expires-at verification-data)) ERR-VERIFICATION-EXPIRED)
    
    ;; Check attempt limit
    (asserts! (< (get attempts verification-data) (var-get max-verification-attempts)) ERR-INVALID-VERIFICATION-CODE)
    
    ;; Verify code
    (asserts! (is-eq code-hash (get code-hash verification-data)) ERR-INVALID-VERIFICATION-CODE)
    
    ;; Mark as verified
    (map-set verification-codes
      { player: tx-sender, verification-type: verification-type }
      (merge verification-data { verified: true })
    )
    
    ;; Update player verification level
    (let 
      (
        (current-level (get verification-level player-data))
        (new-verification-level (if (> verification-type current-level) verification-type current-level))
        (new-status (if (is-eq (get status player-data) STATUS-PENDING) STATUS-ACTIVE (get status player-data)))
      )
      (map-set players
        { player: tx-sender }
        (merge player-data {
          verification-level: new-verification-level,
          status: new-status,
          kyc-verified: (if (is-eq verification-type VERIFICATION-KYC) true (get kyc-verified player-data))
        })
      )
    )
    
    (ok true)
  )
)

;; Update activity timestamp
(define-public (update-activity)
  (let 
    (
      (player-data (unwrap! (map-get? players { player: tx-sender }) ERR-PLAYER-NOT-FOUND))
      (current-block stacks-block-height)
    )
    (map-set players
      { player: tx-sender }
      (merge player-data { last-active: current-block })
    )
    
    (ok true)
  )
)

;; Admin functions

;; Suspend a player (admin only)
(define-public (suspend-player 
  (target-player principal)
  (reason (string-utf8 300))
)
  (let 
    (
      (admin-permissions (unwrap! (map-get? player-permissions { player: tx-sender }) ERR-NOT-AUTHORIZED))
      (target-data (unwrap! (map-get? players { player: target-player }) ERR-PLAYER-NOT-FOUND))
      (action-id (var-get next-action-id))
      (current-block stacks-block-height)
    )
    ;; Check admin permissions
    (asserts! (get is-admin admin-permissions) ERR-NOT-AUTHORIZED)
    
    ;; Suspend player
    (map-set players
      { player: target-player }
      (merge target-data { status: STATUS-SUSPENDED })
    )
    
    ;; Record admin action
    (map-set admin-actions
      { action-id: action-id }
      {
        admin: tx-sender,
        target-player: target-player,
        action-type: "SUSPEND",
        reason: reason,
        timestamp: current-block,
        active: true
      }
    )
    
    (var-set next-action-id (+ action-id u1))
    
    (ok true)
  )
)

;; Unsuspend a player (admin only)
(define-public (unsuspend-player (target-player principal))
  (let 
    (
      (admin-permissions (unwrap! (map-get? player-permissions { player: tx-sender }) ERR-NOT-AUTHORIZED))
      (target-data (unwrap! (map-get? players { player: target-player }) ERR-PLAYER-NOT-FOUND))
      (action-id (var-get next-action-id))
      (current-block stacks-block-height)
    )
    ;; Check admin permissions
    (asserts! (get is-admin admin-permissions) ERR-NOT-AUTHORIZED)
    
    ;; Unsuspend player
    (map-set players
      { player: target-player }
      (merge target-data { status: STATUS-ACTIVE })
    )
    
    ;; Record admin action
    (map-set admin-actions
      { action-id: action-id }
      {
        admin: tx-sender,
        target-player: target-player,
        action-type: "UNSUSPEND",
        reason: u"Administrative action",
        timestamp: current-block,
        active: true
      }
    )
    
    (var-set next-action-id (+ action-id u1))
    
    (ok true)
  )
)

;; Grant admin privileges (contract owner only)
(define-public (grant-admin (target-player principal))
  (let 
    (
      (target-permissions (default-to 
        { can-create-elections: false, can-vote: false, can-moderate: false, is-admin: false }
        (map-get? player-permissions { player: target-player })
      ))
    )
    ;; Only contract owner can grant admin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    ;; Update permissions
    (map-set player-permissions
      { player: target-player }
      (merge target-permissions { is-admin: true, can-moderate: true })
    )
    
    (ok true)
  )
)

;; Lock/unlock player profile (admin only)
(define-public (toggle-profile-lock (target-player principal))
  (let 
    (
      (admin-permissions (unwrap! (map-get? player-permissions { player: tx-sender }) ERR-NOT-AUTHORIZED))
      (target-data (unwrap! (map-get? players { player: target-player }) ERR-PLAYER-NOT-FOUND))
    )
    ;; Check admin permissions
    (asserts! (get is-admin admin-permissions) ERR-NOT-AUTHORIZED)
    
    ;; Toggle profile lock
    (map-set players
      { player: target-player }
      (merge target-data { profile-locked: (not (get profile-locked target-data)) })
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get player profile
(define-read-only (get-player (player principal))
  (map-get? players { player: player })
)

;; Get player by username
(define-read-only (get-player-by-username (username (string-ascii 50)))
  (match (map-get? player-usernames { username: username })
    some-mapping (map-get? players { player: (get player some-mapping) })
    none
  )
)

;; Get player permissions
(define-read-only (get-player-permissions (player principal))
  (map-get? player-permissions { player: player })
)

;; Get player statistics
(define-read-only (get-player-stats (player principal))
  (map-get? player-stats { player: player })
)

;; Check if player can perform action
(define-read-only (can-player-action (player principal) (action (string-ascii 20)))
  (let 
    (
      (player-data (map-get? players { player: player }))
      (permissions (map-get? player-permissions { player: player }))
    )
    (match player-data
      some-player
        (match permissions
          some-perms
            (and 
              (not (is-eq (get status some-player) STATUS-SUSPENDED))
              (not (is-eq (get status some-player) STATUS-BANNED))
              (if (is-eq action "CREATE_ELECTION")
                (get can-create-elections some-perms)
                (if (is-eq action "VOTE")
                  (get can-vote some-perms)
                  (if (is-eq action "MODERATE")
                    (get can-moderate some-perms)
                    false
                  )
                )
              )
            )
          false
        )
      false
    )
  )
)

;; Check verification status
(define-read-only (get-verification-status (player principal) (verification-type uint))
  (match (map-get? verification-codes { player: player, verification-type: verification-type })
    some-verification (get verified some-verification)
    false
  )
)

;; Get admin action
(define-read-only (get-admin-action (action-id uint))
  (map-get? admin-actions { action-id: action-id })
)

;; Get total players count
(define-read-only (get-total-players)
  (var-get total-players)
)

;; Check if username is available
(define-read-only (is-username-available (username (string-ascii 50)))
  (is-none (map-get? player-usernames { username: username }))
)

;; Helper functions for stats updates (to be called by other contracts)

;; Update player stats (election contract integration)
(define-public (update-player-stats
  (player principal)
  (stat-type (string-ascii 20))
  (increment uint)
)
  (let 
    (
      (current-stats (default-to
        { elections-created: u0, elections-voted: u0, total-votes-cast: u0, 
          referrals-made: u0, reports-filed: u0, warnings-received: u0 }
        (map-get? player-stats { player: player })
      ))
    )
    ;; Only allow calls from contract owner or admin
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER)
                  (default-to false (get is-admin (map-get? player-permissions { player: tx-sender }))))
              ERR-NOT-AUTHORIZED)
    
    ;; Update appropriate stat
    (map-set player-stats
      { player: player }
      (if (is-eq stat-type "ELECTION_CREATED")
        (merge current-stats { elections-created: (+ (get elections-created current-stats) increment) })
        (if (is-eq stat-type "ELECTION_VOTED")
          (merge current-stats { elections-voted: (+ (get elections-voted current-stats) increment) })
          (if (is-eq stat-type "VOTE_CAST")
            (merge current-stats { total-votes-cast: (+ (get total-votes-cast current-stats) increment) })
            (if (is-eq stat-type "REFERRAL_MADE")
              (merge current-stats { referrals-made: (+ (get referrals-made current-stats) increment) })
              (if (is-eq stat-type "REPORT_FILED")
                (merge current-stats { reports-filed: (+ (get reports-filed current-stats) increment) })
                (if (is-eq stat-type "WARNING_RECEIVED")
                  (merge current-stats { warnings-received: (+ (get warnings-received current-stats) increment) })
                  current-stats
                )
              )
            )
          )
        )
      )
    )
    
    (ok true)
  )
)