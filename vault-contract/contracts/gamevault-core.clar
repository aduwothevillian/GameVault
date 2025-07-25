;; gamevault-core.clar
;; Main contract orchestrating all GameVault systems
;; Version: 1.0.0

;; ===================
;; Constants & Errors
;; ===================

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-CONTRACT-PAUSED (err u1001))
(define-constant ERR-INVALID-CONTRACT (err u1002))
(define-constant ERR-ALREADY-INITIALIZED (err u1003))
(define-constant ERR-NOT-INITIALIZED (err u1004))
(define-constant ERR-INVALID-GAME (err u1005))
(define-constant ERR-INVALID-PLAYER (err u1006))
(define-constant ERR-INVALID-PARAMETER (err u1007))
(define-constant ERR-CONTRACT-NOT-FOUND (err u1008))

;; System constants
(define-constant CONTRACT-VERSION "1.0.0")
(define-constant MAX-GAMES u1000)
(define-constant MAX-CONTRACTS u20)

;; ===================
;; Data Variables
;; ===================

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; System status
(define-data-var is-initialized bool false)
(define-data-var is-paused bool false)

;; Version tracking
(define-data-var contract-version (string-ascii 16) CONTRACT-VERSION)

;; Counters for contracts and games
(define-data-var contract-count uint u0)
(define-data-var game-count uint u0)

;; ===================
;; Data Maps
;; ===================

;; Contract registry - stores addresses of all system contracts
(define-map contract-registry
  { contract-name: (string-ascii 64) }
  { 
    contract-address: principal,
    version: (string-ascii 16),
    enabled: bool,
    last-updated: uint
  }
)

;; Game registry - stores basic info about registered games
(define-map game-registry
  { game-id: (string-ascii 64) }
  { 
    name: (string-utf8 256),
    developer: principal,
    created-at: uint,
    active: bool
  }
)

;; Admin registry - stores system administrators
(define-map admin-registry
  { admin: principal }
  { 
    role: (string-ascii 32),
    added-by: principal,
    added-at: uint,
    active: bool
  }
)

;; ===================
;; Authorization Functions
;; ===================

;; Check if caller is contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; Check if caller is an admin
(define-private (is-admin)
  (default-to 
    false
    (get active (map-get? admin-registry { admin: tx-sender }))
  )
)

;; Check if caller is authorized (owner or admin)
(define-private (is-authorized)
  (or (is-contract-owner) (is-admin))
)

;; Check if system is active
(define-private (is-system-active)
  (and (var-get is-initialized) (not (var-get is-paused)))
)

;; ===================
;; Initialization & Configuration
;; ===================

;; Initialize the contract
(define-public (initialize)
  (begin
    ;; Only owner can initialize
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Can't initialize twice
    (asserts! (not (var-get is-initialized)) ERR-ALREADY-INITIALIZED)
    
    ;; Set as initialized
    (var-set is-initialized true)
    
    ;; Set initial version
    (var-set contract-version CONTRACT-VERSION)
    
    ;; Log initialization
    (print { event: "system-initialized", version: CONTRACT-VERSION })
    
    (ok true)
  )
)

;; Transfer contract ownership
(define-public (transfer-ownership (new-owner principal))
  (begin
    ;; Only current owner can transfer ownership
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Set new owner
    (var-set contract-owner new-owner)
    
    ;; Log ownership transfer
    (print { event: "ownership-transferred", from: tx-sender, to: new-owner })
    
    (ok true)
  )
)

;; Pause the system
(define-public (pause-system)
  (begin
    ;; Only authorized users can pause
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    
    ;; Set paused state
    (var-set is-paused true)
    
    ;; Log system pause
    (print { event: "system-paused", by: tx-sender })
    
    (ok true)
  )
)

;; Unpause the system
(define-public (unpause-system)
  (begin
    ;; Only owner can unpause
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Set unpaused state
    (var-set is-paused false)
    
    ;; Log system unpause
    (print { event: "system-unpaused", by: tx-sender })
    
    (ok true)
  )
)

;; ===================
;; Admin Management
;; ===================

;; Add a new admin
(define-public (add-admin (admin principal) (role (string-ascii 32)))
  (begin
    ;; Only owner can add admins
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Add admin to registry
    (map-set admin-registry
      { admin: admin }
      { 
        role: role,
        added-by: tx-sender,
        added-at: stacks-block-height,
        active: true
      }
    )
    
    ;; Log admin addition
    (print { event: "admin-added", admin: admin, role: role })
    
    (ok true)
  )
)

;; Remove an admin
(define-public (remove-admin (admin principal))
  (begin
    ;; Only owner can remove admins
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Get current admin data
    (let ((admin-data (map-get? admin-registry { admin: admin })))
      ;; Update admin status
      (asserts! (is-some admin-data) ERR-INVALID-PARAMETER)
      
      (map-set admin-registry
        { admin: admin }
        (merge (unwrap-panic admin-data) { active: false })
      )
    )
    
    ;; Log admin removal
    (print { event: "admin-removed", admin: admin })
    
    (ok true)
  )
)

;; Check if a principal is an admin
(define-read-only (check-admin (admin principal))
  (default-to 
    false
    (get active (map-get? admin-registry { admin: admin }))
  )
)

;; ===================
;; Contract Registry Management
;; ===================

;; Register a contract
(define-public (register-contract (contract-name (string-ascii 64)) (contract-address principal) (version (string-ascii 16)))
  (begin
    ;; Only authorized users can register contracts
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    
    ;; System must be initialized
    (asserts! (var-get is-initialized) ERR-NOT-INITIALIZED)
    
    ;; Check if contract already exists
    (let ((existing-contract (map-get? contract-registry { contract-name: contract-name })))
      ;; If it's a new contract, increment the counter
      (if (is-none existing-contract)
        (var-set contract-count (+ (var-get contract-count) u1))
        true
      )
    )
    
    ;; Register the contract
    (map-set contract-registry
      { contract-name: contract-name }
      { 
        contract-address: contract-address,
        version: version,
        enabled: true,
        last-updated: stacks-block-height
      }
    )
    
    ;; Log contract registration
    (print { 
      event: "contract-registered", 
      name: contract-name, 
      address: contract-address,
      version: version
    })
    
    (ok true)
  )
)

;; Update a contract
(define-public (update-contract (contract-name (string-ascii 64)) (contract-address principal) (version (string-ascii 16)))
  (begin
    ;; Only authorized users can update contracts
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    
    ;; System must be initialized
    (asserts! (var-get is-initialized) ERR-NOT-INITIALIZED)
    
    ;; Check if contract exists
    (asserts! (is-some (map-get? contract-registry { contract-name: contract-name })) ERR-CONTRACT-NOT-FOUND)
    
    ;; Update the contract
    (map-set contract-registry
      { contract-name: contract-name }
      { 
        contract-address: contract-address,
        version: version,
        enabled: true,
        last-updated: stacks-block-height
      }
    )
    
    ;; Log contract update
    (print { 
      event: "contract-updated", 
      name: contract-name, 
      address: contract-address,
      version: version
    })
    
    (ok true)
  )
)

;; Disable a contract
(define-public (disable-contract (contract-name (string-ascii 64)))
  (begin
    ;; Only authorized users can disable contracts
    (asserts! (is-authorized) ERR-NOT-AUTHORIZED)
    
    ;; Get current contract data
    (let ((contract-data (map-get? contract-registry { contract-name: contract-name })))
      ;; Check if contract exists
      (asserts! (is-some contract-data) ERR-CONTRACT-NOT-FOUND)
      
      ;; Update contract status
      (map-set contract-registry
        { contract-name: contract-name }
        (merge (unwrap-panic contract-data) { enabled: false, last-updated: stacks-block-height })
      )
    )
    
    ;; Log contract disabling
    (print { event: "contract-disabled", name: contract-name })
    
    (ok true)
  )
)

;; Get contract address
(define-read-only (get-contract-address (contract-name (string-ascii 64)))
  (let ((contract-data (map-get? contract-registry { contract-name: contract-name })))
    (if (and (is-some contract-data) (get enabled (unwrap-panic contract-data)))
      (ok (get contract-address (unwrap-panic contract-data)))
      ERR-CONTRACT-NOT-FOUND
    )
  )
)

;; Check if a contract is registered and enabled
(define-read-only (is-contract-available (contract-name (string-ascii 64)))
  (let ((contract-data (map-get? contract-registry { contract-name: contract-name })))
    (if (is-some contract-data)
      (get enabled (unwrap-panic contract-data))
      false
    )
  )
)

;; ===================
;; Game Registry Management
;; ===================

;; Register a new game
(define-public (register-game (game-id (string-ascii 64)) (name (string-utf8 256)))
  (begin
    ;; System must be active
    (asserts! (is-system-active) ERR-CONTRACT-PAUSED)
    
    ;; Check if game already exists
    (let ((existing-game (map-get? game-registry { game-id: game-id })))
      ;; If it's a new game, increment the counter
      (if (is-none existing-game)
        (var-set game-count (+ (var-get game-count) u1))
        true
      )
    )
    
    ;; Register the game
    (map-set game-registry
      { game-id: game-id }
      { 
        name: name,
        developer: tx-sender,
        created-at: stacks-block-height,
        active: true
      }
    )
    
    ;; Log game registration
    (print { 
      event: "game-registered", 
      game-id: game-id, 
      name: name,
      developer: tx-sender
    })
    
    (ok true)
  )
)

;; Deactivate a game
(define-public (deactivate-game (game-id (string-ascii 64)))
  (begin
    ;; System must be active
    (asserts! (is-system-active) ERR-CONTRACT-PAUSED)
    
    ;; Get current game data
    (let ((game-data (map-get? game-registry { game-id: game-id })))
      ;; Check if game exists
      (asserts! (is-some game-data) ERR-INVALID-GAME)
      
      ;; Check if caller is developer or admin
      (asserts! (or 
        (is-eq tx-sender (get developer (unwrap-panic game-data)))
        (is-authorized)
      ) ERR-NOT-AUTHORIZED)
      
      ;; Update game status
      (map-set game-registry
        { game-id: game-id }
        (merge (unwrap-panic game-data) { active: false })
      )
    )
    
    ;; Log game deactivation
    (print { event: "game-deactivated", game-id: game-id })
    
    (ok true)
  )
)

;; Check if game is active
(define-read-only (is-game-active (game-id (string-ascii 64)))
  (default-to 
    false
    (get active (map-get? game-registry { game-id: game-id }))
  )
)

;; Get game details
(define-read-only (get-game-details (game-id (string-ascii 64)))
  (map-get? game-registry { game-id: game-id })
)

;; ===================
;; System Information
;; ===================

;; Get system status
(define-read-only (get-system-status)
  {
    initialized: (var-get is-initialized),
    paused: (var-get is-paused),
    version: (var-get contract-version),
    owner: (var-get contract-owner)
  }
)

;; Get contract count
(define-read-only (get-contract-count)
  (var-get contract-count)
)

;; Get game count
(define-read-only (get-game-count)
  (var-get game-count)
)

;; Get all registered contract names (for reference)
(define-read-only (get-registered-contracts)
  (list 
    "player-management"
    "game-state-storage" 
    "achievement-system"
    "leaderboard-manager"
    "asset-management"
    "economic-system"
  )
)

;; ===================
;; Emergency Functions
;; ===================

;; Emergency upgrade of contract version
(define-public (emergency-upgrade (new-version (string-ascii 16)))
  (begin
    ;; Only owner can perform emergency upgrade
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Update version
    (var-set contract-version new-version)
    
    ;; Log emergency upgrade
    (print { 
      event: "emergency-upgrade", 
      old-version: CONTRACT-VERSION, 
      new-version: new-version
    })
    
    (ok true)
  )
)

;; Emergency function to handle critical issues
(define-public (emergency-action (action-type (string-ascii 64)) (params (list 10 (string-ascii 64))))
  (begin
    ;; Only owner can perform emergency actions
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Log emergency action
    (print { 
      event: "emergency-action", 
      action-type: action-type,
      params: params
    })
    
    (ok true)
  )
)