#!/usr/bin/env swift
import Contacts
import Foundation

func digits(_ number: String) -> String { return number.filter { $0.isNumber } }

func parseArgs(_ args: [String]) -> [(field: String, query: String)] {
  stride(from: 1, to: args.count - 1, by: 2).map { i in
    (args[i], args[i + 1])
  }
}

func fetchContacts(searchPairs: [(field: String, query: String)]) {
  let store = CNContactStore()
  let keysToFetch = [
    CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    CNContactPhoneNumbersKey as CNKeyDescriptor,
    CNContactEmailAddressesKey as CNKeyDescriptor,
  ]

  let request = CNContactFetchRequest(keysToFetch: keysToFetch)
  var resultsBySearch: [String: [[String: Any]]] = [:]

  // Init empty arrays for each search
  searchPairs.forEach { pair in
    resultsBySearch["\(pair.field):\(pair.query)"] = []
  }

  do {
    try store.enumerateContacts(with: request) { contact, _ in
      let displayName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
      let phones     = contact.phoneNumbers.map { $0.value.stringValue }
      let emails     = contact.emailAddresses.map { $0.value as String }

      // Check each search pair against contact
      searchPairs.forEach { field, query in
        let matches = switch field {
          case "--name":  displayName.range(of: query, options: .caseInsensitive) != nil
          case "--phone": phones.contains { digits($0).contains(digits(query)) }
          case "--email": emails.contains { $0.range(of: query, options: .caseInsensitive) != nil }
          default:    false
        }
        if !matches { return }

        resultsBySearch["\(field):\(query)"]?.append([
          "name":   displayName,
          "phones": phones,
          "emails": emails,
        ])
      }
    }

    let jsonData = try JSONSerialization.data(withJSONObject: resultsBySearch, options: .prettyPrinted)
    guard let jsonString = String(data: jsonData, encoding: .utf8) else { return }
    print(jsonString)

  } catch {
    print("Error: \(error)")
  }
}

guard CommandLine.arguments.count > 2 && CommandLine.arguments.count % 2 == 1 else {
  print("Usage: contacts-cli [--name|--phone|--email <value>]...")
  exit(1)
}

let pairs = parseArgs(CommandLine.arguments)
fetchContacts(searchPairs: pairs)
