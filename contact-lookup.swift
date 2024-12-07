#!/usr/bin/env swift
import Contacts
import Foundation

func digits(_ number: String) -> String { return number.filter { $0.isNumber } }

func fetchContacts(matching field: String, _ query: String) {
  let store = CNContactStore()
  let keysToFetch = [
    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    CNContactPhoneNumbersKey as CNKeyDescriptor,
    CNContactEmailAddressesKey as CNKeyDescriptor
  ]

  let request = CNContactFetchRequest(keysToFetch: keysToFetch)
  var results = [[String: Any]]()

  do {
    try store.enumerateContacts(with: request) { contact, _ in
      let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
      let phones    = contact.phoneNumbers.map { $0.value.stringValue }
      let emails    = contact.emailAddresses.map { $0.value as String }

      let matches = switch field {
        case "--name":  displayName.range(of: query, options: .caseInsensitive) != nil
        case "--phone": phones.contains { digits($0).contains(digits(query)) }
        case "--email": emails.contains { $0.range(of: query, options: .caseInsensitive) != nil }
        default:    false
      }
      if !matches { return }

      results.append([
        "name":   displayName,
        "phones": phones,
        "emails": emails,
      ])
    }

    let jsonData = try JSONSerialization.data(withJSONObject: results, options: .prettyPrinted)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
    print(jsonString)

  } catch {
    print("Error fetching contacts: \(error)")
  }
}

// CLI Argument Handling
let args = CommandLine.arguments
guard args.count == 3 else {
  print("Usage: contacts-cli --name|--phone|--email <partial string>")
  exit(1)
}

let (field, query) = (args[1], args[2])
fetchContacts(matching: field, query)
