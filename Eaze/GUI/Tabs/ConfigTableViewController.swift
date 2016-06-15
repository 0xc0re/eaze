//
//  ConfigTableViewController.swift
//  CleanflightMobile
//
//  Created by Alex on 22-11-15.
//  Copyright © 2015 Hangar42. All rights reserved.
//
//   Note: Because of a bug in iOS we can only use the splitViewController on iPads. This means we have to use
//   replace segues on an iPad and push segues on iPhones. To keep the storyboard clean we do this in code.
//   Hence the storyboardNames array..

import UIKit

class ConfigTableViewController: UITableViewController/*: GroupedTableViewController*/ {
    
    
    // MARK: - Variables
    
    private let storyboardNames = [["General", "Receiver", "Motors", "Serial", "ReceiverInput"], ["AppPrefs", "AppLog", "AboutApp"]]
    private var currentSelection = (section: 99, row: 99),
                isLoading = false
    
    
    // MARK: - Functions
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        //splitViewController?.view.backgroundColor = globals.colorTableBackground
    }
    
    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        tableView.deselectRowAtIndexPath(indexPath, animated: true)
        
        // prevent EXC_BAD_ACCESS when loading the view multiple times at the same time (possible since we're doing it async)
        /*if indexPath.section == currentSelection.section && indexPath.row == currentSelection.row {
            return
        } else {
            currentSelection = (section: indexPath.section, row: indexPath.row)
        }*/
        
        guard !isLoading else { return }
        isLoading = true
        
        // load vc async for better performance
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            let vc = self.storyboard!.instantiateViewControllerWithIdentifier(self.storyboardNames[indexPath.section][indexPath.row])
            
            dispatch_async(dispatch_get_main_queue()) {
                self.isLoading = false
                if let split = self.splitViewController {
                    split.viewControllers[1] = UINavigationController(rootViewController: vc)
                } else {
                    self.navigationController?.pushViewController(vc, animated: true)
                }
            }
        }
    }
}