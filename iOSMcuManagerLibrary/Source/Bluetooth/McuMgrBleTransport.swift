/*
 * Copyright (c) 2017-2018 Runtime Inc.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Modified by Jarrod Moldrich, 2026
 */

import Foundation
import CoreBluetooth

// MARK: - PeripheralState

public enum PeripheralState {
    /// State set when the manager starts connecting with the
    /// peripheral.
    case connecting
    /// State set when the peripheral gets connected and the
    /// manager starts service discovery.
    case initializing
    /// State set when device becomes ready, that is all required
    /// services have been discovered and notifications enabled.
    case connected
    /// State set when close() method has been called.
    case disconnecting
    /// State set when the connection to the peripheral has closed.
    case disconnected
}

// MARK: - PeripheralDelegate

public protocol PeripheralDelegate: AnyObject {
    /// Callback called whenever peripheral state changes.
    func peripheral(_ peripheral: CBPeripheral, didChangeStateTo state: PeripheralState)
}

// MARK: - McuMgrBleTransport

public class McuMgrBleTransport: NSObject {
    
    /// The CBCentralManager instance from which the peripheral was obtained.
    /// This is used to connect and cancel connection.
    internal var centralManager: CBCentralManager
    /// The queue used to buffer requests when another one is in progress.
    private let operationQueue: OperationQueue
    /// Used to track multiple write requests and their responses.
    internal var writeState: McuMgrBleTransportWriteState
    /// Used to track the Sequence Number the chunked responses belong to.
    internal var previousUpdateNotificationSequenceNumber: McuSequenceNumber?
    
    internal lazy var robWriteBuffer = McuMgrBleROBWriteBuffer(logDelegate)
    
    /// Bare metal isn't supported in this fork so we only need one peripheral
    internal var peripheral: CBPeripheral
    
    /// SMP Characteristic object. Used to write requests and receive
    /// notifications.
    internal var smpCharacteristic: CBCharacteristic?
    
    public var mtu: Int! {
        didSet {
            log(msg: "MTU set to \(mtu)", atLevel: .info)
        }
    }
    
    // Fork does not support bare metal
    public var mode: McuMgrTransportMode {
        return .default
    }
    
    /// An array of observers.
    private var observers: [ConnectionObserver]

    /// The log delegate will receive transport logs.
    public weak var logDelegate: McuMgrLogDelegate?
    
    /// Set to values larger than 1 to enable Parallel Writes
    ///
    /// Features like SMP Pipelining are based on the concept of multiple packet transmissions happening
    /// at the same time and waiting for their responses as they're received. By default,`McuMgrBleTransport`
    /// only sends one Data transmission at a time. But if set to higher values, calls to
    /// ``send(data: Data, timeout: Int, callback: @escaping McuMgrCallback<T>)`` will be handled
    /// concurrently.
    public var numberOfParallelWrites: Int {
        set {
            operationQueue.maxConcurrentOperationCount = max(1, newValue)
        }
        get {
            operationQueue.maxConcurrentOperationCount
        }
    }
    
    /// Enable when calling ``send(data: Data, timeout: Int, callback: @escaping McuMgrCallback<T>)``
    /// with `Data` values larger than MTU Size, such as when SMP Reassembly feature is enabled.
    ///
    /// If the Data being sent is larger than the MTU Size, this property  should be enabled so it's cut-down
    /// to MTU Size so as to keep within each transmission packet's maximum (MTU) size limit. Otherwise, it's
    /// likely that CoreBluetooth will not send the Data.
    public var chunkSendDataToMtuSize: Bool = false

    /// Creates a transport using a pre-established managed connection.
    ///
    /// - Parameters:
    ///   - peripheral: The connected CBPeripheral
    ///   - centralManager: The CBCentralManager
    ///   - smpCharacteristic: The discovered SMP characteristic with notifications enabled
    public init(
        peripheral: CBPeripheral,
        centralManager: CBCentralManager,
        smpCharacteristic: CBCharacteristic
    ) {
        self.peripheral = peripheral
        self.centralManager = centralManager
        self.smpCharacteristic = smpCharacteristic
        self.writeState = McuMgrBleTransportWriteState()
        self.observers = []
        self.operationQueue = OperationQueue()
        self.operationQueue.qualityOfService = .userInitiated
        self.operationQueue.maxConcurrentOperationCount = 1

        super.init()

        // Set MTU based on peripheral's negotiated value
        let negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let defaultMtu = McuManager.getDefaultMtu(scheme: .ble)
        self.mtu = min(negotiatedMTU, defaultMtu)

        log(msg: "McuMgrBleTransport initialized with MTU: \(self.mtu!)", atLevel: .info)
    }

    /// Called when an SMP characteristic notification is received.
    /// This forwards the data to the write state machine to complete pending operations.
    ///
    /// - Parameters:
    ///   - data: The notification data
    ///   - error: Any error from the notification
    public func handleNotification(data: Data?, error: Error?) {
        if let error = error {
            writeState.onError(error)
            return
        }

        guard let data = data else {
            writeState.onError(McuMgrTransportError.badResponse)
            return
        }

        // Check if this is a continuation of a previous chunked response
        if let previousSeq = previousUpdateNotificationSequenceNumber,
           !writeState.isChunkComplete(for: previousSeq) {
            writeState.received(sequenceNumber: previousSeq, data: data)
            return
        }

        // New response - extract sequence number from header
        guard let sequenceNumber = data.readMcuMgrHeaderSequenceNumber() else {
            writeState.onError(McuMgrTransportError.badResponse)
            return
        }

        previousUpdateNotificationSequenceNumber = sequenceNumber
        writeState.received(sequenceNumber: sequenceNumber, data: data)
    }

    /// Called when the peripheral is ready to accept more writes.
    ///
    /// - Parameter peripheral: The peripheral that is ready
    public func handlePeripheralReadyToWrite(_ peripheral: CBPeripheral) {
        robWriteBuffer.peripheralReadyToWrite(peripheral)
    }

    /// Call this to notify observers that the connection was lost.
    /// Should be called when the peripheral disconnects.
    public func didDisconnect() {
        softReset()
        notifyStateChanged(.disconnected)
    }
    
    /// Signal reconnection to transport.  Peripheral, CentralManager, and characteristic instances
    /// may have changed so they should be resupplied.  This should be signalled after the
    /// SMP service has been re-enumerated
    public func didReconnect(peripheral: CBPeripheral, centralManager: CBCentralManager, smpCharacteristic: CBCharacteristic) {
        self.peripheral = peripheral
        self.centralManager = centralManager
        self.smpCharacteristic = smpCharacteristic
        softReset()
        notifyStateChanged(.connected)
    }
}

// MARK: - McuMgrTransport

extension McuMgrBleTransport: McuMgrTransport {
    
    public func getScheme() -> McuMgrScheme {
        return .ble
    }
    
    public func switchMode(to newMode: McuMgrTransportMode, with modeParameter: Any?) throws {
        // Fork does not support bare metal / bootloader mode switching
        throw McuMgrBleTransportError.alreadyInRequestedMode
    }
    
    public func send<T: McuMgrResponse>(data: Data, timeout: Int, callback: @escaping McuMgrCallback<T>) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let `self` = self else { return }
            guard let `operation` = operation else { return }

            for i in 0..<McuMgrBleTransportConstant.MAX_RETRIES {
                if operation.isCancelled { return }
                let result = self._send(data: data, timeoutInSeconds: timeout)
                if operation.isCancelled { return }
                switch result {
                case .failure(McuMgrTransportError.waitAndRetry):
                    let waitInterval = min(timeout, McuMgrBleTransportConstant.WAIT_AND_RETRY_INTERVAL)
                    sleep(UInt32(waitInterval))
                    if let header = try? McuMgrHeader(data: data) {
                        self.log(msg: "Retry \(i + 1) for seq: \(header.sequenceNumber)", atLevel: .info)
                    } else {
                        self.log(msg: "Retry \(i + 1) (Unknown Header Type)", atLevel: .info)
                    }
                case .failure(McuMgrTransportError.peripheralNotReadyForWriteWithoutResponse):
                    if let header = try? McuMgrHeader(data: data) {
                        self.log(msg: "(Retry \(i + 1)) Peripheral not ready for write without response. Attempting to wait or send seq: \(header.sequenceNumber)", atLevel: .debug)
                    }
                    continue // try to send again or wait for a response
                case .failure(let error):
                    self.log(msg: error.localizedDescription, atLevel: .error)
                    DispatchQueue.main.async {
                        callback(nil, error)
                    }
                    return
                case .success(let responseData):
                    do {
                        let response: T = try McuMgrResponse.buildResponse(scheme: .ble, data: responseData)
                        DispatchQueue.main.async {
                            callback(response, nil)
                        }
                    } catch {
                        self.log(msg: error.localizedDescription, atLevel: .error)
                        DispatchQueue.main.async {
                            callback(nil, error)
                        }
                    }
                    return
                }
            }
            
            // Out of for-loop. No callback call was made.
            // If we made it here, all retries failed.
            DispatchQueue.main.async {
                if !operation.isCancelled {
                    callback(nil, McuMgrTransportError.sendFailed)
                }
            }
        }
        
        operationQueue.addOperation(operation)
    }
    
    public func connect(_ callback: @escaping ConnectionCallback) {
        callback(.deferred)
    }
    
    public func close() {
        log(msg: "close() called - connection managed externally", atLevel: .debug)
    }
    
    public func addObserver(_ observer: ConnectionObserver) {
        observers.append(observer)
    }
    
    public func removeObserver(_ observer: ConnectionObserver) {
        if let index = observers.firstIndex(where: {$0 === observer}) {
            observers.remove(at: index)
        }
    }
    
    internal func notifyStateChanged(_ state: McuMgrTransportState) {
        // The list of observers may be modified by each observer.
        // Better iterate a copy of it.
        let array = [ConnectionObserver](observers)
        for observer in array {
            observer.transport(self, didChangeStateTo: state)
        }
    }
    
    /**
     Clean any necessary state between Peripheral Connections.
     
     Multiple heavy-duty operations may be performed using the same 'transport' instance. To
     prevent issues and attempt to improve reliability, it's better to wipe any lingering state.
     */
    internal func softReset() {
        previousUpdateNotificationSequenceNumber = nil
        operationQueue.cancelAllOperations()
        writeState = McuMgrBleTransportWriteState()
        robWriteBuffer = McuMgrBleROBWriteBuffer(logDelegate)
    }
    
    /// This method sends the data to the target. Before, it ensures that
    /// CBCentralManager is ready and the peripheral is connected.
    /// The peripheral will automatically be connected when it's not.
    ///
    /// - returns: A `Result` containing the full response `Data` if successful, `Error` if not. Note that if `McuMgrTransportError.waitAndRetry` is returned, said operation needs to be done externally to this call.
    private func _send(data: Data, timeoutInSeconds: Int) -> Result<Data, Error> {
        // Verify peripheral is still connected
        guard peripheral.state == .connected else {
            return .failure(McuMgrTransportError.disconnected)
        }

        // Verify central manager is powered on
        guard centralManager.state == .poweredOn else {
            return .failure(McuMgrBleTransportError.centralManagerPoweredOff)
        }

        // Extract sequence number from data
        guard let sequenceNumber = data.readMcuMgrHeaderSequenceNumber() else {
            return .failure(McuMgrTransportError.badHeader)
        }
        
        // Create a lock for this write operation
        let writeLock = ResultLock(isOpen: false)
        writeLock.close()
        writeState.newWrite(sequenceNumber: sequenceNumber, lock: writeLock)
        
        // No matter what, if we exit from now due to error or success, clear
        // the current Sequence Number.
        defer {
            assert(writeState[sequenceNumber]?.writeLock.isOpen ?? true)
            writeState.completedWrite(sequenceNumber: sequenceNumber)
        }
        
        // Don't be smart caching the MTU.
        let negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
        // It's possible an upper-layer has set a non-max MTU. Either by mistake, or by design.
        // We only want to force the MTU value to change if the current value causes issues.
        if mtu > negotiatedMTU {
            log(msg: "peripheral.maximumWriteValueLength(for: .withoutResponse): \(negotiatedMTU) > Current MTU (\(mtu))", atLevel: .debug)
            mtu = negotiatedMTU
        }
        
        // if reassembly {
        if chunkSendDataToMtuSize {
            var dataChunks = [Data]()
            var dataChunksSize = 0
            while dataChunksSize < data.count {
                let i = dataChunks.count
                let chunkSize = min(data.count - dataChunksSize, mtu)
                dataChunksSize += chunkSize
                dataChunks.append(data[(i * mtu)..<(i * mtu + chunkSize)])
            }
            
            guard dataChunksSize == data.count else {
                let error = McuMgrTransportError.badChunking
                writeState.open(sequenceNumber: sequenceNumber, dueTo: error)
                return .failure(error)
            }
            
            robWriteBuffer.enqueue(sequenceNumber, data: dataChunks, to: peripheral, characteristic: smpCharacteristic!) { [weak self] chunk, error in
                if let error = error {
                    writeLock.open(error)
                    return
                }
                if let chunk = chunk {
                    self?.log(msg: "-> [Seq: \(sequenceNumber)] \(chunk.hexEncodedString(options: [.upperCase, .twoByteSpacing])) (\(chunk.count) bytes)", atLevel: .debug)
                }
            }
        } else {
            // No SMP Reassembly Supported. So no 'chunking'.
            guard data.count <= mtu else {
                log(msg: "Error: \(data.count)-byte packet is larger than MTU Size (\(mtu)) without Reassembly being enabled.", atLevel: .error)
                let error = McuMgrTransportError.insufficientMtu(mtu: mtu)
                writeState.open(sequenceNumber: sequenceNumber, dueTo: error)
                return .failure(error)
            }

            robWriteBuffer.enqueue(sequenceNumber, data: [data], to: peripheral, characteristic: smpCharacteristic!) { [weak self] chunk, error in
                if let error = error {
                    writeLock.open(error)
                    return
                }
                if let chunk = chunk {
                    self?.log(msg: "-> [Seq: \(sequenceNumber)] \(chunk.hexEncodedString(options: [.upperCase, .twoByteSpacing])) (\(chunk.count) bytes)", atLevel: .debug)
                }
            }
        }

        // Wait for the didUpdateValueFor(characteristic:) to open the lock.
        let result = writeLock.block(timeout: DispatchTime.now() + .seconds(timeoutInSeconds))
        
        switch result {
        case .failure(McuMgrTransportError.sendTimeout):
            guard !robWriteBuffer.isInFlight(sequenceNumber) else {
                writeLock.open(McuMgrTransportError.peripheralNotReadyForWriteWithoutResponse)
                return .failure(McuMgrTransportError.peripheralNotReadyForWriteWithoutResponse)
            }
            writeLock.open(McuMgrTransportError.waitAndRetry)
            return .failure(McuMgrTransportError.waitAndRetry)
        case .failure(let error):
            writeLock.open(error)
            return .failure(error)
        case .success:
            guard let returnData = writeState[sequenceNumber]?.chunk else {
                return .failure(McuMgrTransportError.badHeader)
            }
            log(msg: "<- [Seq: \(sequenceNumber)] \(returnData.hexEncodedString(options: [.upperCase, .twoByteSpacing])) (\(returnData.count) bytes)", atLevel: .debug)
            return .success(returnData)
        }
    }
    
    internal func log(msg: @autoclosure () -> String, atLevel level: McuMgrLogLevel) {
        if let logDelegate, level >= logDelegate.minLogLevel() {
            logDelegate.log(msg(), ofCategory: .transport, atLevel: level)
        }
    }
}

// MARK: - McuMgrBleTransportConstant

public enum McuMgrBleTransportConstant {
    /// Max number of retries until the transaction is failed.
    internal static let MAX_RETRIES = 3
    /// The interval to wait before attempting a transaction again in seconds.
    internal static let WAIT_AND_RETRY_INTERVAL = 10
    /// Connection timeout in seconds.
    internal static let CONNECTION_TIMEOUT = 20
}

// MARK: - McuMgrBleTransportKey

internal enum McuMgrBleTransportKey: ResultLockKey {
    case awaitingCentralManager = "McuMgrBleTransport.awaitingCentralManager"
    case discoveringSmpCharacteristic = "McuMgrBleTransport.discoveringSmpCharacteristic"
}

// MARK: - McuMgrBleTransportError

public enum McuMgrBleTransportError: Error, LocalizedError {
    case centralManagerPoweredOff
    case centralManagerNotReady
    case missingService
    case missingCharacteristic
    case missingNotifyProperty
    case alreadyInRequestedMode
    case modeSwitchRequestedWithPeripheralStillConnected
    case modeSwitchRequestedWithoutPeripheral
    
    public var errorDescription: String? {
        switch self {
        case .centralManagerPoweredOff:
            return "Central Manager powered OFF."
        case .centralManagerNotReady:
            return "Central Manager not ready."
        case .missingService:
            return "SMP service not found."
        case .missingCharacteristic:
            return "SMP characteristic not found."
        case .missingNotifyProperty:
            return "SMP characteristic does not have notify property."
        case .alreadyInRequestedMode:
            return "Cannot change mode since transport is already in the requested mode."
        case .modeSwitchRequestedWithPeripheralStillConnected :
            return "Cannot switch mode (CBPeripheral) when the previous mode (CBPeripheral) is still connected to this transport."
        case .modeSwitchRequestedWithoutPeripheral:
            return "There's no CBPeripheral attached to the requested mode switch."
        }
    }
}
