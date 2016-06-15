//
//  BluetoothSerial.swift
//  For communication with HM10 BLE UART modules
//
//  Created by Alex on 09-08-15.
//  Copyright (c) 2015 Hangar42. All rights reserved.
//
//  HM10's service UUID is FFE0, the characteristic we need is FFE1
//
//  RSSI goes from about -40 to -100 (which is when it looses signal)
//
//  How viewcontrollers should implement communication with the FC:
//  1) In viewDidLoad
//      a) subscribe to the MSP codes you're going to send (at least those you need the reaction of..)
//      b) if already connected, send MSP codes and enable buttons etc
//      c) if not connected, disable buttons etc
//  2) Subscribe to BluetoothSerialDidConnectNotification (*)
//      in whose selector you send MSP codes and enable buttons etc
//  3) Subscribe to BluetoothSerialDidDisconnectNotification
//      in whose selector you disable buttons etc
//  4) Implement the MSPSubscriber protocol (if neccesary) and put a switch statement in there
//      in which you update the UI and other stuff according to the code (data) received
//
//  If the viewController sends continous msp data requests, it needs to start the timer in
//  viewWillAppear, AppDidBecomeActive and serialDidOpen (the latter two only if isBeingShown)
//  It then stops the timer in viewWillDisappear, AppWillResignActive and serialDidClose (again, the latter two only if isBeingShown).
//
//  Note: yes, you can use sendMSP(code, callback), but its purpose is for notifications of events (calibration, reset etc), not UI updates.
//  *: In case the VC is still in memory while connecting - the actual connecting does only happen on the Dashboard tab.

///TODO: TEST DIDFAILTOCONNECT NOTIFICATION!

import UIKit
import CoreBluetooth

// Notifications sent by BluetoothSerial
let BluetoothSerialWillAutoConnectNotification = "BluetoothSerialWillConnect"
let BluetoothSerialDidConnectNotification = "BluetoothSerialDidConnect"
let BluetoothSerialDidFailToConnectNotification = "BluetoothSerialDidFailToConnect"
let BluetoothSerialDidDisconnectNotification = "BluetoothSerialDidDisconnect"
let BluetoothSerialDidDiscoverNewPeripheralNotification = "BluetoothSerialDidDiscoverNewPeripheral"
let BluetoothSerialDidUpdateStateNotification = "BluetoothDidUpdateState"
let BluetoothSerialDidStopScanningNotification = "BluetoothDidStopScanning"


let SerialOpenedNotification = BluetoothSerialDidConnectNotification
let SerialClosedNotification = BluetoothSerialDidDisconnectNotification

protocol BluetoothSerialDelegate {
    func serialPortReceivedData(data: NSData)
}


final class BluetoothSerial: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // MARK: - Variables
    
    /// The CBCentralManager this bluetooth serial handler uses for communication
    var centralManager: CBCentralManager!
    
    /// The peripheral we are currently trying to connect to/trying to verify (nil if none)
    var pendingPeripheral: CBPeripheral?
    
    /// The connected peripheral (nil if none is connected). This device is ready to receive MSP/CLI commands
    var connectedPeripheral: CBPeripheral?
    
    /// The characteristic we need to write to
    weak var writeCharacteristic: CBCharacteristic?
    
    /// The peripherals that have been discovered (no duplicates and sorted by asc RSSI)
    var discoveredPeripherals: [(peripheral: CBPeripheral!, RSSI: Float)] = []
    
    /// The state of the bluetooth manager (use this to determine whether it is on or off or disabled etc)
    var state: CBCentralManagerState {
        get { return centralManager.state }
    }
    
    /// Whether we're scanning for devices right now
    var isScanning: Bool {
        get { return centralManager.isScanning }
    }
    
    /// Whether we're currently trying to connect to/verify a peripheral
    var isConnecting: Bool {
        get { return pendingPeripheral != nil }
    }
    
    /// Whether the serial port is open and ready to send or receive data
    var isConnected: Bool {
        get { return connectedPeripheral != nil }
    }
    
    /// Whether we can currently write
    var isReadyToWrite: Bool {
        get { return isConnected && writeCharacteristic != nil }
    }
    
    /// WriteType we use to write data to the peripheral
    var writeType = CBCharacteristicWriteType.WithResponse
    
    /// Function called the next time some data is received (to be used for testing purposes)
    var callbackOnReceive: (Void -> Void)?
    
    /// Function called when RSSI is read
    var rssiCallback: (NSNumber -> Void)?
    
    /// The object that will be notified of new data arriving
    var delegate: BluetoothSerialDelegate?
    
    
    // MARK: - Functions
    
    /// Initializor
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    /// Start scanning for peripherals
    func startScan() {
        guard centralManager.state == .PoweredOn else { return }
        log("Start scanning")
        
        discoveredPeripherals = []
        
        // search for devices with correct service UUID, and allow duplicates for RSSI update (but only if it is needed for auto connecting new peripherals)
        centralManager.scanForPeripheralsWithServices([CBUUID(string: "FFE0")], options: [CBCentralManagerScanOptionAllowDuplicatesKey: userDefaults.boolForKey(DefaultsAutoConnectNewKey)])
        
        // maybe the peripheral is still connected
        for peripheral in centralManager.retrieveConnectedPeripheralsWithServices([CBUUID(string: "FFE0")]) {
            evaluatePeripheral(peripheral, RSSI: nil)
        }
    }
    
    /// Try to connect to the given peripheral
    func connectToPeripheral(peripheral: CBPeripheral) {
        guard centralManager.state == .PoweredOn else { return }
        log("Connecting to peripheral \(peripheral.name ?? "Unknown")")
        
        pendingPeripheral = peripheral
        centralManager.connectPeripheral(peripheral, options: nil)
        delay(10) {
            // timeout
            guard self.isConnecting else { return }
            log("Connection timeout")
            self.disconnect()
            notificationCenter.postNotificationName(BluetoothSerialDidFailToConnectNotification, object: nil)
        }
    }
    
    /// Stop scanning for new peripherals
    func stopScan() {
        guard centralManager.state == .PoweredOn else { return }
        log("Stopped scanning")
        
        centralManager.stopScan()
        notificationCenter.postNotificationName(BluetoothSerialDidStopScanningNotification, object: nil)
    }
    
    /// Disconnect from the connected peripheral (to be used while already connected to it)
    func disconnect() {
        guard centralManager.state == .PoweredOn else { return }
        log("Disconnecting")
        
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        } else if let p = pendingPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }
    
    /// Send an array of raw bytes to the HM10
    func sendBytesToDevice(bytes: [UInt8]) {
        guard isReadyToWrite else { return }
                
        let data = NSData(bytes: bytes, length: bytes.count)
        connectedPeripheral!.writeValue(data, forCharacteristic: writeCharacteristic!, type: writeType)
    }
    
    /// Send a string to the HM10 (only supports 8-bit UTF8 encoding)
    func sendStringToDevice(string: String) {
        guard isReadyToWrite else { return }
        
        if let data = string.dataUsingEncoding(NSUTF8StringEncoding) {
            connectedPeripheral!.writeValue(data, forCharacteristic: writeCharacteristic!, type: writeType)
        }
    }
    
    /// Send a NSData object to the HM10
    func sendDataToDevice(data: NSData) {
        guard isReadyToWrite else { return }
        
        connectedPeripheral!.writeValue(data, forCharacteristic: writeCharacteristic!, type: writeType)
    }
    
    /// Read RSSI
    func readRSSI(callback: NSNumber -> Void) {
        guard isConnected else { return }
        rssiCallback = callback
        connectedPeripheral!.readRSSI()
    }
    
    func evaluatePeripheral(peripheral: CBPeripheral, RSSI: NSNumber?) {
        log("RSSI: \(RSSI?.integerValue) Name: \(peripheral.name ?? "noidea")")
        
        // this order of functions might seem a little confusing at first..
        // but this is done for a reason
        
        // check if we already know this device
        var isKnown = false,
            autoConnect = false
        if BluetoothDevice.devices.filter({ $0.UUID.isEqual(peripheral.identifier) }).count > 0 {
            isKnown = true
        }
        
        // we do this before checking for duplicates for RSSI updates
        if userDefaults.boolForKey(DefaultsAutoConnectNewKey) && RSSI?.integerValue > -70 && !isKnown {
            stopScan()
            connectToPeripheral(peripheral)
            notificationCenter.postNotificationName(BluetoothSerialWillAutoConnectNotification, object: nil)
            autoConnect = true
        }
        
        // stop if it is a duplicate
        for exisiting in discoveredPeripherals {
            if exisiting.peripheral.identifier == peripheral.identifier { return }
        }
        
        // auto connect if we already know this device
        if userDefaults.boolForKey(DefaultsAutoConnectOldKey) && isKnown {
            stopScan()
            connectToPeripheral(peripheral)
            notificationCenter.postNotificationName(BluetoothSerialWillAutoConnectNotification, object: nil)
            autoConnect = true
        }
        
        // add to the array, next sort & reload & send notification
        discoveredPeripherals.append((peripheral: peripheral, RSSI: RSSI?.floatValue ?? -100.0))
        discoveredPeripherals.sortInPlace { $0.RSSI < $1.RSSI }
        
        notificationCenter.postNotificationName(BluetoothSerialDidDiscoverNewPeripheralNotification, object: nil, userInfo: ["WillAutoConnect": autoConnect])
    }
    
    
    // MARK: - CBCentralManagerDelegate functions
    
    func centralManager(central: CBCentralManager, didDiscoverPeripheral peripheral: CBPeripheral, advertisementData: [String : AnyObject], RSSI: NSNumber) {
        evaluatePeripheral(peripheral, RSSI: RSSI)
    }
    
    func centralManager(central: CBCentralManager, didConnectPeripheral peripheral: CBPeripheral) {
        peripheral.delegate = self
        
        // Okay, the peripheral is connected but we're not ready yet!
        // First get the 0xFFE0 service
        // Then get the characteristics 0xFFE1 of this service
        // Subscribe to it, keep a reference to it (for writing later on)
        // And then we're ready for communication
        // If this does not happen within 10 seconds, we've failed and have to find another device..
        
        peripheral.discoverServices([CBUUID(string: "FFE0")])
    }
    
    func centralManager(central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        pendingPeripheral = nil
        connectedPeripheral = nil
        writeCharacteristic = nil
        msp.reset()
        
        notificationCenter.postNotificationName(BluetoothSerialDidDisconnectNotification, object: nil)
    }
    
    func centralManager(central: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        pendingPeripheral = nil
        notificationCenter.postNotificationName(BluetoothSerialDidFailToConnectNotification, object: nil)
    }
    
    func centralManagerDidUpdateState(central: CBCentralManager) {
        if state != .PoweredOn {
            if isConnected { //TODO: Further test this
                notificationCenter.postNotificationName(BluetoothSerialDidDisconnectNotification, object: nil)
            } else if isConnecting {
                notificationCenter.postNotificationName(BluetoothSerialDidFailToConnectNotification, object: nil)
            }
            pendingPeripheral = nil
            connectedPeripheral = nil
            writeCharacteristic = nil
            discoveredPeripherals = []
        }
        
        notificationCenter.postNotificationName(BluetoothSerialDidUpdateStateNotification, object: nil)
    }


// MARK: - CBPeripheralDelegate functions
    
    func peripheral(peripheral: CBPeripheral, didDiscoverServices error: NSError?) {
        // discover FFE1 characteristics for all services
        for service in peripheral.services! {
            peripheral.discoverCharacteristics([CBUUID(string: "FFE1")], forService: service)
        }
    }
    
    func peripheral(peripheral: CBPeripheral, didDiscoverCharacteristicsForService service: CBService, error: NSError?) {
        // check whether the characteristic we're looking for (0xFFE1) is present
        for characteristic in service.characteristics! {
            if characteristic.UUID == CBUUID(string: "FFE1") {
                // subscribe to this value (so we'll get notified when there is serial data for us..)
                peripheral.setNotifyValue(true, forCharacteristic: characteristic)
                
                // now we can send data to the peripheral
                pendingPeripheral = nil
                connectedPeripheral = peripheral
                writeCharacteristic = characteristic
                var verified = false
                
                // Before we're ready we have to check (If we don't know this peripheral yet)
                // 1) Whether we have to write with or without response
                // 2) Whether it actually repsonds
                // 3) Whether CLI mode is activated
                // To do this, we'll
                // 1) Send an MSP command without response
                // 2) (If unresponsive) Send an MSP command with response
                // 3) (If still unresponsive) Send 'asdf\r' without response
                //    3b) If responsive send 'exit\r' to exit CLI mode
                // 4) (If still unresponsive) Send 'asdf\r' with response
                //    4b) If responsive send 'exit\r' to exit CLI mode
                // 5) (If still unresponsive) Abort connection and send notification
                //
                // If we do know this peripheral, we will only check if CLI mode is activated
                //
                
                func ready() {
                    verified = true
                    
                    // we already got MSP_API_VERSION, so let's check the min and max versions
                    if dataStorage.apiVersion >= apiMaxVersion || dataStorage.apiVersion < apiMinVersion {
                        log(.Warn, "API version not compatible. API: \(dataStorage.apiVersion) MSP: \(dataStorage.mspVersion)")
                        
                        let alert = UIAlertController(title: "Firmware not compatible", message: "The API version is either too old or too new.", preferredStyle: .Alert)
                        alert.addAction(UIAlertAction(title: "Dismiss", style: .Default) { _ in cancel() })
                        
                        var rootViewController = UIApplication.sharedApplication().keyWindow?.rootViewController
                        while let newRoot = rootViewController?.presentedViewController { rootViewController = newRoot }
                        rootViewController?.presentViewController(alert, animated: true, completion: nil)
                        
                        return
                    }
                    
                    // add to our list of recognized devices
                    if BluetoothDevice.deviceWithUUID(peripheral.identifier) == nil {
                        BluetoothDevice.devices.append(BluetoothDevice(name: peripheral.name ?? "Unidentified",
                                                                       UUID: peripheral.identifier,
                                                                autoConnect: true,
                                                          writeWithResponse: writeType == .WithResponse))
                        BluetoothDevice.saveDevices()
                    }
                    
                    // send first MSP commands for the board info stuff
                    msp.sendMSP([MSP_FC_VARIANT, MSP_FC_VERSION, MSP_BOARD_INFO, MSP_BUILD_INFO]) {
                        log("Connected and ready to rock and roll")
                        log("API v\(dataStorage.apiVersion.stringValue)")
                        log("MSP v\(dataStorage.mspVersion)")
                        log("FC ID \(dataStorage.flightControllerIdentifier)")
                        log("FC v\(dataStorage.flightControllerVersion)")
                        log("Board ID \(dataStorage.boardIdentifier)")
                        log("Board v\(dataStorage.boardVersion)")
                        log("Build \(dataStorage.buildInfo)")
                        
                        // these only have to be sent once
                        msp.sendMSP([MSP_BOXNAMES, MSP_STATUS])
                        
                        // the user will be happy to know
                        MessageView.show("Connected")
                        
                        // proceed to tell the rest of the app about recent events
                        notificationCenter.postNotificationName(BluetoothSerialDidConnectNotification, object: nil)
                    }
                }
                
                func fail() {
                    guard !verified else { return }
                    
                    log("Module not responding")
                    
                    let alert = UIAlertController(title: "Module not responding", message: "Connect anyway?", preferredStyle: .Alert)
                    alert.addAction(UIAlertAction(title: "Connect", style: .Cancel) { _ in ready() })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .Default) { _ in cancel() })
                    
                    var rootViewController = UIApplication.sharedApplication().keyWindow?.rootViewController
                    while let newRoot = rootViewController?.presentedViewController { rootViewController = newRoot }
                    rootViewController?.presentViewController(alert, animated: true, completion: nil)
                }
                
                func cancel() {
                    disconnect()
                    notificationCenter.postNotificationName(BluetoothSerialDidFailToConnectNotification, object: nil)
                }
                
                func exitCLI() {
                    sendStringToDevice("exit\r")
                    msp.sendMSP(MSP_API_VERSION, callback: ready)
                }
                
                func firstTry() {
                    writeType = .WithoutResponse
                    msp.sendMSP(MSP_API_VERSION, callback: ready)
                    delay(1.0, closure: secondTry)
                }
                
                func secondTry() {
                    guard !verified else { return }
                    writeType = .WithResponse
                    msp.sendMSP(MSP_API_VERSION) // callback is still in place
                    delay(1.0, closure: thirdTry)
                }
                
                func thirdTry() {
                    guard !verified else { return }
                    msp.callbacks = [] // clear previous callback
                    writeType = .WithoutResponse
                    callbackOnReceive = exitCLI
                    sendStringToDevice("asdf\r")
                    delay(1.0, closure: fourthTry)
                }
                
                func fourthTry() {
                    guard !verified else { return }
                    writeType = .WithResponse
                    sendStringToDevice("asdf\r")
                    delay(1.0, closure: fail)
                }
                
                func smartFirstTry() {
                    writeType = BluetoothDevice.deviceWithUUID(peripheral.identifier)!.writeWithResponse ? .WithResponse : .WithoutResponse
                    msp.sendMSP(MSP_API_VERSION, callback: ready)
                    delay(1.0, closure: smartSecondTry)
                }
                
                func smartSecondTry() {
                    guard !verified else { return }
                    callbackOnReceive = exitCLI
                    sendStringToDevice("asdf\r")
                    delay(1.0, closure: fail)
                }
                
                if BluetoothDevice.deviceWithUUID(peripheral.identifier) != nil {
                    smartFirstTry()
                } else {
                    firstTry()
                }
            }
        }
    }
    
    func peripheral(peripheral: CBPeripheral, didUpdateValueForCharacteristic characteristic: CBCharacteristic, error: NSError?) {
        
        if callbackOnReceive != nil {
            callbackOnReceive?()
            callbackOnReceive = nil
        }
        
        delegate?.serialPortReceivedData(characteristic.value!)
    }
    
    func peripheral(peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: NSError?) {
        rssiCallback?(RSSI)
    }
}